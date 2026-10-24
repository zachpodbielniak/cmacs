;;; cmacs-gowl-hotkey-tests.el --- Tests for gowl hotkeys from Elisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Elisp half of gowl's hotkey module (AutoHotkey for gowl): the
;; entry a `cmacs-gowl-hotkey-define' call turns into, Lisp data as the
;; module's YAML, the refusals made before anything is sent, the opt-in
;; startup, Elisp functions and contexts, the module's announcements
;; driving the state and the hooks, the RPC entry points that never
;; signal, and the D-Bus, MCP and emacsctl surfaces.
;;
;; Two kinds of test keep the documentation honest: the cookbook in
;; etc/cmacs/examples/gowl-hotkey-examples.el is loaded against a fake
;; compositor and every line it sends is checked, and every Elisp block
;; the manual shows (doc_org/cmacs/gowl.org, doc/cmacs/cmacs.texi) must
;; be text of that file.  The last test runs the real module in a second
;; cmacs on gowl's headless backend.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-gowl-hotkey)

;; Special, so the fake-compositor `let' below binds them dynamically
;; and `add-hook' lands in the binding (cmacs-gowl.el, which defines
;; them, is not loaded by these tests).
(defvar cmacs-gowl-module-event-functions)
(defvar cmacs-gowl-focus-changed-functions)
(defvar cmacs-gowl-client-title-changed-functions)

(defconst cmacs-gowl-hotkey-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, for finding the source tree.")

(defun cmacs-gowl-hotkey-tests--source-file (relative)
  "RELATIVE (to the source tree root) as an absolute name, or nil."
  (let ((f (expand-file-name (concat "../../" relative)
                             (file-name-directory
                              cmacs-gowl-hotkey-tests--this-file))))
    (and (file-readable-p f) f)))

(defun cmacs-gowl-hotkey-tests--parse (json)
  "JSON as alists and lists."
  (json-parse-string json :object-type 'alist :array-type 'list
                     :false-object :false :null-object nil))

(defun cmacs-gowl-hotkey-tests--added (line)
  "The JSON of a `hotkey-add' LINE (after any --id=), parsed."
  (cmacs-gowl-hotkey-tests--parse
   (replace-regexp-in-string "\\`hotkey-add \\(--id=[^ ]+ \\)?" "" line)))

(defmacro cmacs-gowl-hotkey-tests--with-clean-state (&rest body)
  "Run BODY with every piece of this session's hotkey state empty."
  (declare (indent 0))
  `(let ((cmacs-gowl-hotkey--functions (make-hash-table :test #'equal))
         (cmacs-gowl-hotkey--named-functions (make-hash-table :test #'equal))
         (cmacs-gowl-hotkey--contexts (make-hash-table :test #'equal))
         (cmacs-gowl-hotkey--context-values (make-hash-table :test #'equal))
         (cmacs-gowl-hotkey--defined nil)
         (cmacs-gowl-hotkey--sections nil)
         (cmacs-gowl-hotkey--enabled nil)
         (cmacs-gowl-hotkey--suspended nil)
         (cmacs-gowl-hotkey--mode nil)
         (cmacs-gowl-hotkey--context-timer nil)
         (cmacs-gowl-hotkey-enable nil)
         (cmacs-gowl-hotkey-definitions nil)
         (cmacs-gowl-hotkey-remaps nil)
         (cmacs-gowl-hotkey-hotstrings nil)
         (cmacs-gowl-hotkey-section nil)
         (cmacs-gowl-hotkey-scripts nil)
         (cmacs-gowl-hotkey-fired-functions nil)
         (cmacs-gowl-hotkey-fault-functions nil)
         (cmacs-gowl-hotkey-changed-functions nil)
         (cmacs-gowl-hotkey-input-functions nil)
         (cmacs-gowl-module-event-functions nil)
         (cmacs-gowl-focus-changed-functions nil)
         (cmacs-gowl-client-title-changed-functions nil))
     ,@body))

(defmacro cmacs-gowl-hotkey-tests--with-fake-gowl (&rest body)
  "Run BODY with a fake running compositor that records commands.
Binds `enabled' (module loads), `configured' (settings pushed),
`commands' (every line sent, newest first) and `focused' (what
`gowl-client-info' answers for the focused window)."
  (declare (indent 0))
  `(let ((enabled nil) (configured nil) (commands nil) (focused nil))
     (ignore focused)
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-enable-module)
                (lambda (&rest args) (push args enabled) t))
               ((symbol-function 'gowl-disable-module)
                (lambda (&rest _) t))
               ((symbol-function 'gowl-configure-module)
                (lambda (&rest args) (push args configured) t))
               ((symbol-function 'gowl-focused-client)
                (lambda (&rest _) (and focused 'client)))
               ((symbol-function 'gowl-client-info)
                (lambda (&rest _) focused))
               ((symbol-function 'gowl-run-command)
                (lambda (line &rest _)
                  (push line commands)
                  (cond ((equal line "hotkey-status")
                         (and enabled
                              "OK {\"suspended\":false,\"mode\":\"default\",\"hotkeys\":3,\"remaps\":1}"))
                        ((string-prefix-p "hotkey-add" line) "OK added x")
                        ((equal line "hotkey-list")
                         "OK [{\"id\":\"#!c\",\"key\":\"#!c\",\"canonical\":\"#!c\",\"enabled\":true}]")
                        ((string-prefix-p "hotkey-frob" line)
                         "ERROR unknown command")
                        (t "OK")))))
       ,@body)))

;;;; Entries

(ert-deftest cmacs-gowl-hotkey-test-entry ()
  "A define call becomes the entry the module reads: id, key, filters,
options, and the :do actions before the Elisp call."
  (let ((e (cmacs-gowl-hotkey-tests--parse
            (json-serialize
             (cmacs-gowl-hotkey-entry
              "#!c" #'ignore
              :when '(and (app-id "librewolf") (title ~ "Docs"))
              :over "app-id=org.example.Music"
              :context "work" :mode "*" :double t :hold 700 :priority 2
              :suspend-exempt t :enabled nil :description "x"
              :do '((:send "^c") (:sleep 150)))))))
    (should (equal (alist-get 'id e) "#!c"))
    (should (equal (alist-get 'key e) "#!c"))
    (should (equal (alist-get 'context e) "work"))
    (should (equal (alist-get 'mode e) "*"))
    (should (eq (alist-get 'double e) t))
    (should (eql (alist-get 'hold e) 700))
    (should (eql (alist-get 'priority e) 2))
    (should (eq (alist-get 'suspend-exempt e) t))
    (should (eq (alist-get 'enabled e) :false))
    (should (equal (alist-get 'over e) "app-id=org.example.Music"))
    (should (string-match-p "app-id" (alist-get 'when e)))
    (should (string-match-p "Docs" (alist-get 'when e)))
    (should (equal (alist-get 'do e)
                   '(((send . "^c")) ((sleep . 150))
                     ((custom . "(cmacs-gowl-hotkey--call %i %t)")))))))

(ert-deftest cmacs-gowl-hotkey-test-entry-shapes ()
  "An :id names it; :do may be one plist, a command line, or nothing
when there is a function; `hotkey-add' gets one section."
  (let ((e (cmacs-gowl-hotkey-entry "F9" nil :id "shot"
                                    :do '(:shell "grim ~/s.png"))))
    (should (equal (alist-get 'id e) "shot"))
    (should (equal (alist-get 'do e) [((shell . "grim ~/s.png"))])))
  (should (equal (alist-get 'do (cmacs-gowl-hotkey-entry "F9" nil
                                                         :do "view 2"))
                 ["view 2"]))
  (let ((sec (cmacs-gowl-hotkey-tests--parse
              (cmacs-gowl-hotkey-entry-json "F9" #'ignore))))
    (should (equal (alist-get 'key (car (alist-get 'hotkeys sec))) "F9"))))

(ert-deftest cmacs-gowl-hotkey-test-refusals ()
  "Mistakes are refused where they are made, before anything is sent."
  (should-error (cmacs-gowl-hotkey-entry "F9" #'ignore :sneeze t)
                :type 'user-error)
  (should-error (cmacs-gowl-hotkey-entry "F9" nil) :type 'user-error)
  (should-error (cmacs-gowl-hotkey-entry "" #'ignore) :type 'user-error)
  (should-error (cmacs-gowl-hotkey-entry "F9" #'ignore :double 'often)
                :type 'user-error)
  (should-error (cmacs-gowl-hotkey-entry "F9" #'ignore :id "two words")
                :type 'user-error)
  (cmacs-gowl-hotkey-tests--with-clean-state
    (should-error (cmacs-gowl-hotkey-define "F9" 'not-a-function-anywhere)
                  :type 'user-error)
    (should-error (cmacs-gowl-hotkey-define-function "a b" #'ignore)
                  :type 'user-error)
    (should-error (cmacs-gowl-hotkey-define-context "x" "not a function")
                  :type 'user-error)
    (should-not cmacs-gowl-hotkey--defined)))

(ert-deftest cmacs-gowl-hotkey-test-yaml-data ()
  "Lisp data becomes the module's YAML: plists and alists mappings,
lists and vectors sequences, t and nil booleans; text passes through."
  (should (equal (cmacs-gowl-hotkey-yaml "remaps: {a: b}") "remaps: {a: b}"))
  (let ((d (cmacs-gowl-hotkey-tests--parse
            (cmacs-gowl-hotkey-yaml
             '(:hotkeys [(:key "#r" :do (:mode resize))]
               :remaps (("CapsLock" . "Control_L"))
               :modes (:resize (:oneshot t :swallow nil)))))))
    (should (equal (alist-get 'hotkeys d)
                   '(((key . "#r") (do (mode . "resize"))))))
    (should (equal (alist-get 'remaps d) '((CapsLock . "Control_L"))))
    (should (equal (alist-get 'resize (alist-get 'modes d))
                   '((oneshot . t) (swallow . :false))))))

;;;; Startup

(ert-deftest cmacs-gowl-hotkey-test-opt-in-startup ()
  "Nothing configured, nothing loaded; `enable' loads it with settings."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (cmacs-gowl-hotkey--on-start)
      (should-not enabled)
      (should-not commands)
      (setq cmacs-gowl-hotkey-enable t
            cmacs-gowl-hotkey-scripts '("/tmp/a.c" "/tmp/b.c"))
      (cmacs-gowl-hotkey--on-start)
      (should (equal enabled '(("hotkey"))))
      (let ((settings (cadr (car configured))))
        (should (equal (alist-get "suspend-key" settings nil nil #'equal)
                       "Super+Shift+Pause"))
        (should (equal (alist-get "dbus" settings nil nil #'equal) "false"))
        (should (equal (alist-get "scripts" settings nil nil #'equal)
                       "/tmp/a.c,/tmp/b.c")))
      (should (memq #'cmacs-gowl-hotkey--on-module-event
                    cmacs-gowl-module-event-functions)))))

(ert-deftest cmacs-gowl-hotkey-test-configured-is-a-reason ()
  "Remaps, hotstrings or definitions alone load the module; the options
arrive as one section with a fixed id, the definitions as hotkeys."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (setq cmacs-gowl-hotkey-remaps '(("CapsLock" . "Control_L"))
          cmacs-gowl-hotkey-hotstrings '("::btw::by the way" ("brb" . "be right back"))
          cmacs-gowl-hotkey-definitions '(("#!c" ignore :description "c")))
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (cmacs-gowl-hotkey--on-start)
      (should (equal enabled '(("hotkey"))))
      (let* ((sent (reverse commands))
             (opts (cl-find-if (lambda (l)
                                 (string-prefix-p "hotkey-add --id=cmacs-options "
                                                  l))
                               sent))
             (hk (cl-find-if (lambda (l) (string-match-p "\"#!c\"" l)) sent)))
        (should opts)
        (let ((d (cmacs-gowl-hotkey-tests--added opts)))
          (should (equal (alist-get 'remaps d) '((CapsLock . "Control_L"))))
          (should (equal (alist-get 'hotstrings d)
                         '("::btw::by the way"
                           ((trigger . "brb") (replace . "be right back"))))))
        (should hk)
        (should (eq (gethash "#!c" cmacs-gowl-hotkey--functions) 'ignore))))))

(ert-deftest cmacs-gowl-hotkey-test-define-before-start ()
  "Defined before the compositor runs: kept, installed when it starts,
and defining the same id again replaces it."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (cmacs-gowl-hotkey-define "#!c" #'ignore)
      (cmacs-gowl-hotkey-define "#!c" #'identity :description "second")
      (should (= (length cmacs-gowl-hotkey--defined) 1))
      (should (eq (gethash "#!c" cmacs-gowl-hotkey--functions) #'identity)))
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (cmacs-gowl-hotkey--on-start)
      (let ((add (cl-find-if (lambda (l) (string-prefix-p "hotkey-add" l))
                             commands)))
        (should add)
        (should (equal (alist-get 'description
                                  (car (alist-get 'hotkeys
                                                  (cmacs-gowl-hotkey-tests--added
                                                   add))))
                       "second"))))))

(ert-deftest cmacs-gowl-hotkey-test-define-loads-module ()
  "Defining a hotkey with the compositor up is a first use."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (cmacs-gowl-hotkey-define "#!c" #'ignore)
      (should (equal enabled '(("hotkey"))))
      (should (cl-some (lambda (l) (string-prefix-p "hotkey-add" l)) commands))
      ;; undefine takes it back
      (cmacs-gowl-hotkey-undefine "#!c")
      (should (member "hotkey-remove #!c" commands))
      (should-not (gethash "#!c" cmacs-gowl-hotkey--functions)))))

;;;; Running Elisp

(ert-deftest cmacs-gowl-hotkey-test-call ()
  "The custom form runs the function with the id and trigger bound; an
error is caught and reaches the fault hook."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (let ((seen nil) (faults nil))
      (puthash "k" (lambda ()
                     (push (list cmacs-gowl-hotkey-current
                                 cmacs-gowl-hotkey-trigger)
                           seen))
               cmacs-gowl-hotkey--functions)
      (puthash "bad" (lambda () (error "Boom")) cmacs-gowl-hotkey--functions)
      (add-hook 'cmacs-gowl-hotkey-fault-functions
                (lambda (id what) (push (cons id what) faults)))
      ;; exactly what the module evaluates, %i and %t filled in
      (eval (car (read-from-string
                  "(cmacs-gowl-hotkey--call \"k\" \"hotkey\")"))
            t)
      (should (equal seen '(("k" "hotkey"))))
      (should-not cmacs-gowl-hotkey-current)
      (cmacs-gowl-hotkey--call "bad" "ipc")
      (should (equal faults '(("bad" . "Boom"))))
      ;; an id nobody defined is a message, not an error
      (cmacs-gowl-hotkey--call "nobody" "hotkey"))))

(ert-deftest cmacs-gowl-hotkey-test-functions ()
  "A named Elisp function is defined with a form the module fills in,
and is called with the arguments it gets."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (let ((got nil))
        (cmacs-gowl-hotkey-define-function "tidy"
          (lambda (&rest args) (setq got (list args cmacs-gowl-hotkey-trigger))))
        (should (member "hotkey-func-define tidy (cmacs-gowl-hotkey--call-function \"tidy\" %a %t)"
                        commands))
        ;; %a arrives as (list ...)
        (eval (car (read-from-string
                    "(cmacs-gowl-hotkey--call-function \"tidy\" (list \"a\" \"b c\") \"ipc\")"))
              t)
        (should (equal got '(("a" "b c") "ipc")))
        (cmacs-gowl-hotkey-undefine-function "tidy")
        (should (member "hotkey-func-undefine tidy" commands))))))

(ert-deftest cmacs-gowl-hotkey-test-contexts ()
  "Contexts are asked when the focus moves and only changed answers are
pushed; a predicate that errors is false and a fault."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (let ((faults nil))
        (add-hook 'cmacs-gowl-hotkey-fault-functions
                  (lambda (id _what) (push id faults)))
        (setq focused '((app-id . "librewolf") (title . "x")))
        (cmacs-gowl-hotkey-define-context "browser"
          (lambda (w) (equal (alist-get 'app-id w) "librewolf")))
        (should (memq #'cmacs-gowl-hotkey--refresh-soon
                      cmacs-gowl-focus-changed-functions))
        (should (member "hotkey-context-set browser 1" commands))
        (setq commands nil)
        (cmacs-gowl-hotkey-refresh-contexts)
        (should-not commands)            ; unchanged: nothing pushed
        (setq focused '((app-id . "gst")))
        (cmacs-gowl-hotkey-refresh-contexts)
        (should (equal commands '("hotkey-context-set browser 0")))
        (cmacs-gowl-hotkey-define-context "broken" (lambda (_) (error "No")))
        (should (member "hotkey-context-set broken 0" commands))
        (should (member "broken" faults))
        ;; the focus hook coalesces into one timer
        (cmacs-gowl-hotkey--refresh-soon)
        (cmacs-gowl-hotkey--refresh-soon)
        (should (timerp cmacs-gowl-hotkey--context-timer))
        (cancel-timer cmacs-gowl-hotkey--context-timer)
        (setq cmacs-gowl-hotkey--context-timer nil)
        (cmacs-gowl-hotkey-undefine-context "browser")
        (should (member "hotkey-context-clear browser" commands))))))

(ert-deftest cmacs-gowl-hotkey-test-sections ()
  "A section goes under its id; adding again replaces, removing takes
it back."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (cmacs-gowl-hotkey-add-section "games" '(:remaps (("F13" . "Esc"))))
      (cmacs-gowl-hotkey-add-section "games" "remaps: {F14: Esc}")
      (should (= (length cmacs-gowl-hotkey--sections) 1))
      (should (member "hotkey-add --id=games {\"remaps\":{\"F13\":\"Esc\"}}"
                      commands))
      (should (member "hotkey-add --id=games remaps: {F14: Esc}" commands))
      (cmacs-gowl-hotkey-remove-section "games")
      (should (member "hotkey-remove games" commands))
      (should-not cmacs-gowl-hotkey--sections))))

;;;; Commands and the module's announcements

(ert-deftest cmacs-gowl-hotkey-test-commands ()
  "The command wrappers send the module's words."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (cmacs-gowl-hotkey-suspend)
      (cmacs-gowl-hotkey-suspend 1)
      (cmacs-gowl-hotkey-suspend -1)
      (cmacs-gowl-hotkey-mode-enter "resize")
      (cmacs-gowl-hotkey-send "^a{Delete}")
      (cmacs-gowl-hotkey-send-text "hello")
      (cmacs-gowl-hotkey-fire "x")
      (cmacs-gowl-hotkey-set-enabled "x" nil)
      (cmacs-gowl-hotkey-call "say" "good morning" "x")
      (cmacs-gowl-hotkey-input "tag" :length 2 :timeout 3000 :visible t)
      (dolist (line '("hotkey-suspend toggle" "hotkey-suspend on"
                      "hotkey-suspend off" "hotkey-mode resize"
                      "hotkey-send ^a{Delete}" "hotkey-send-text hello"
                      "hotkey-fire x" "hotkey-disable x"
                      "hotkey-call say good\\ morning x"
                      "hotkey-input-start tag L2 T3000 V"))
        (should (member line commands)))
      (should (equal (alist-get 'hotkeys (cmacs-gowl-hotkey-status)) 3))
      (should (equal (alist-get 'id (car (cmacs-gowl-hotkey-list))) "#!c")))))

(ert-deftest cmacs-gowl-hotkey-test-command-errors ()
  "An ERROR reply is a user-error with the module's own words; no reply
means the module is not loaded."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (should-error (cmacs-gowl-hotkey--command "hotkey-frob")
                    :type 'user-error)
      (should-error (cmacs-gowl-hotkey--command "hotkey-status")
                    :type 'user-error))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (should-error (cmacs-gowl-hotkey--command "hotkey-list")
                    :type 'user-error))))

(ert-deftest cmacs-gowl-hotkey-test-module-events ()
  "The module's announcements drive the hooks, the state and the lighter."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (let ((fired nil) (changed nil) (inputs nil) (faults nil))
      (add-hook 'cmacs-gowl-hotkey-fired-functions (lambda (id) (push id fired)))
      (add-hook 'cmacs-gowl-hotkey-changed-functions
                (lambda (what v) (push (cons what v) changed)))
      (add-hook 'cmacs-gowl-hotkey-input-functions
                (lambda (n r tx) (push (list n r tx) inputs)))
      (add-hook 'cmacs-gowl-hotkey-fault-functions
                (lambda (id what) (push (cons id what) faults)))
      (cmacs-gowl-hotkey--on-module-event "hotkey" "fired CapsLock & j")
      (cmacs-gowl-hotkey--on-module-event "hotkey" "mode resize")
      (should (equal cmacs-gowl-hotkey--mode "resize"))
      (should (string-match-p ":resize" (cmacs-gowl-hotkey--lighter)))
      (cmacs-gowl-hotkey--on-module-event "hotkey" "suspended on key")
      (should cmacs-gowl-hotkey--suspended)
      (should (string-match-p ":off" (cmacs-gowl-hotkey--lighter)))
      (cmacs-gowl-hotkey--on-module-event "hotkey" "suspended off ipc")
      (cmacs-gowl-hotkey--on-module-event "hotkey" "mode default")
      (should-not (cmacs-gowl-hotkey--lighter))
      (cmacs-gowl-hotkey--on-module-event "hotkey" "input tag started")
      (cmacs-gowl-hotkey--on-module-event "hotkey" "input tag max 12")
      (cmacs-gowl-hotkey--on-module-event "hotkey" "fault c action crashed")
      (cmacs-gowl-hotkey--on-module-event "broadcast" "fired nothing")
      (should (equal fired '("CapsLock & j")))
      (should (equal (reverse changed)
                     '((mode . "resize") (suspended . t) (suspended . nil)
                       (mode . "default"))))
      (should (equal inputs '(("tag" "max" "12"))))
      (should (equal faults '((nil . "c action crashed")))))))

(ert-deftest cmacs-gowl-hotkey-test-rpc-never-signals ()
  "The RPC entry points answer ERROR text for every way of failing."
  (cmacs-gowl-hotkey-tests--with-clean-state
    (should (string-prefix-p "ERROR" (cmacs-gowl-hotkey-rpc "sneeze")))
    (should (string-prefix-p "ERROR" (cmacs-gowl-hotkey-rpc "send" "a\nb")))
    (should (string-prefix-p "ERROR" (cmacs-gowl-hotkey-command "view 2")))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (should (string-prefix-p "ERROR" (cmacs-gowl-hotkey-rpc "status"))))
    (cmacs-gowl-hotkey-tests--with-fake-gowl
      (should (string-prefix-p "OK {" (cmacs-gowl-hotkey-rpc "status")))
      (should (equal (cmacs-gowl-hotkey-rpc "suspend" "on") "OK"))
      (should (member "hotkey-suspend on" commands))
      (should (string-prefix-p "ERROR"
                               (cmacs-gowl-hotkey-command "hotkey-frob"))))
    ;; every verb the C whitelist passes, the Lisp one passes too
    (let ((dispatch (cmacs-gowl-hotkey-tests--source-file
                     "cmacs/glib/cmacs-eval-dispatch.c")))
      (when dispatch
        (with-temp-buffer
          (insert-file-contents dispatch)
          (should (re-search-forward "^cmacs_dispatch_gowl_hotkey " nil t))
          (let* ((end (save-excursion (re-search-forward "NULL" nil t)))
                 (verbs nil))
            (while (re-search-forward "\"\\([a-z-]+\\)\"" end t)
              (push (match-string 1) verbs))
            (should (equal (sort verbs #'string<)
                           (sort (copy-sequence cmacs-gowl-hotkey--rpc-verbs)
                                 #'string<)))))))))

;;;; The cookbook and the manual

(defconst cmacs-gowl-hotkey-tests--examples
  "etc/cmacs/examples/gowl-hotkey-examples.el"
  "The Elisp cookbook, relative to the source tree.")

(ert-deftest cmacs-gowl-hotkey-test-examples ()
  "Every recipe in the cookbook loads, and tells the module exactly this."
  (let ((file (cmacs-gowl-hotkey-tests--source-file
               cmacs-gowl-hotkey-tests--examples)))
    (should file)
    (cmacs-gowl-hotkey-tests--with-clean-state
      (let ((cmacs-gowl-hotkey-fired-functions nil)
            (cmacs-gowl-hotkey-fault-functions nil))
        (cmacs-gowl-hotkey-tests--with-fake-gowl
          (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
            (load file nil t))
          ;; nothing sent while the compositor is down; everything kept
          (should-not commands)
          (cmacs-gowl-hotkey--on-start)
          (let* ((sent (reverse commands))
                 (adds (cl-remove-if-not
                        (lambda (l) (string-prefix-p "hotkey-add" l)) sent))
                 (entries
                  (cl-loop for l in adds
                           for d = (cmacs-gowl-hotkey-tests--added l)
                           append (alist-get 'hotkeys d)))
                 (entry (lambda (id)
                          (cl-find id entries :key (lambda (e) (alist-get 'id e))
                                   :test #'equal))))
            ;; capture: copy, wait, then Elisp
            (should (equal (alist-get 'do (funcall entry "#!c"))
                           '(((send . "^c")) ((sleep . 150))
                             ((custom . "(cmacs-gowl-hotkey--call %i %t)")))))
            (should (functionp (gethash "#!c" cmacs-gowl-hotkey--functions)))
            ;; browser: focus-or-start, a named function
            (should (eq (gethash "#!b" cmacs-gowl-hotkey--functions)
                        'my-hotkey-browser))
            ;; per-app: the context exists and the hotkey names it
            (should (gethash "browser" cmacs-gowl-hotkey--contexts))
            (should (equal (alist-get 'context (funcall entry "^+o")) "browser"))
            ;; scratchpad: a command line, then Elisp
            (should (equal (car (alist-get 'do (funcall entry "#!n")))
                           "scratchpad-toggle"))
            ;; push to talk: a press and a release
            (should (equal (alist-get 'key (funcall entry "dictate-up"))
                           "F13 UP"))
            (should (equal (alist-get 'key (funcall entry "dictate-down"))
                           "F13"))
            ;; double tap
            (should (eql (alist-get 'double (funcall entry "RCtrl")) 300))
            ;; game keys stand down in EverQuest
            (dolist (n '(1 2 3))
              (let ((e (funcall entry (format "view-%d" n))))
                (should (equal (alist-get 'do e)
                               `(((command . ,(format "view %d" n))))))
                (should (string-match-p "not" (alist-get 'when e)))
                (should (string-match-p "eqgame.exe" (alist-get 'when e)))))
            ;; functions the YAML calls
            (should (member "hotkey-func-define log-focus (cmacs-gowl-hotkey--call-function \"log-focus\" %a %t)"
                            sent))
            (should (member "hotkey-func-define browser (cmacs-gowl-hotkey--call-function \"browser\" %a %t)"
                            sent))
            ;; sections under their ids
            (let ((log (cl-find-if (lambda (l)
                                     (string-prefix-p "hotkey-add --id=focus-log " l))
                                   sent))
                  (launch (cl-find-if (lambda (l)
                                        (string-prefix-p "hotkey-add --id=launch-mode "
                                                         l))
                                      sent)))
              (should log)
              (should (equal (alist-get 'every
                                        (car (alist-get 'timers
                                                        (cmacs-gowl-hotkey-tests--added
                                                         log))))
                             "1m"))
              (should launch)
              (let ((m (alist-get 'launch
                                  (alist-get 'modes
                                             (cmacs-gowl-hotkey-tests--added
                                              launch)))))
                (should (eq (alist-get 'oneshot m) t))
                (should (= (length (alist-get 'hotkeys m)) 4))))
            ;; options set by the recipe arrive as one section
            (let ((opts (cl-find-if (lambda (l)
                                      (string-prefix-p "hotkey-add --id=cmacs-options "
                                                       l))
                                    sent)))
              (should opts)
              (should (equal (alist-get 'XButton1
                                        (alist-get 'remaps
                                                   (cmacs-gowl-hotkey-tests--added
                                                    opts)))
                             "MButton")))
            ;; the hooks recipe
            (should cmacs-gowl-hotkey-fired-functions)
            (should cmacs-gowl-hotkey-fault-functions)))))))

(defun cmacs-gowl-hotkey-tests--recipes ()
  "The cookbook's recipes as an alist of (TITLE . TEXT).
TEXT is what follows a \";;;; Recipe: TITLE\" line up to the next one,
trimmed."
  (with-temp-buffer
    (insert-file-contents (cmacs-gowl-hotkey-tests--source-file
                           cmacs-gowl-hotkey-tests--examples))
    (let (out)
      (goto-char (point-min))
      (while (re-search-forward "^;;;; Recipe: \\(.*\\)$" nil t)
        (let ((title (match-string 1))
              (start (1+ (line-end-position)))
              (end (save-excursion
                     (if (re-search-forward "^;;;; Recipe: \\|^(provide " nil t)
                         (line-beginning-position)
                       (point-max)))))
          (push (cons title (string-trim (buffer-substring start end))) out)))
      (nreverse out))))

(defun cmacs-gowl-hotkey-tests--org-blocks (file)
  "The `hotkey-example-' named emacs-lisp blocks of org FILE, as strings."
  (with-temp-buffer
    (insert-file-contents file)
    (let (out)
      (goto-char (point-min))
      (while (re-search-forward
              "^#\\+name: hotkey-example-.*\n#\\+begin_src emacs-lisp\n" nil t)
        (let ((start (point)))
          (re-search-forward "^#\\+end_src")
          (push (string-trim
                 (replace-regexp-in-string
                  "^,\\([*#]\\)" "\\1"
                  (buffer-substring start (line-beginning-position))))
                out)))
      (nreverse out))))

(defun cmacs-gowl-hotkey-tests--texi-blocks (file)
  "The @lisp blocks of FILE's Hotkeys section, unescaped, as strings."
  (with-temp-buffer
    (insert-file-contents file)
    (let (out end)
      (goto-char (point-min))
      (when (re-search-forward "^@section Hotkeys (AutoHotkey)" nil t)
        (setq end (save-excursion
                    (if (re-search-forward "^@\\(?:section\\|chapter\\|node\\) "
                                           nil t)
                        (point)
                      (point-max))))
        (while (re-search-forward "^@lisp\n" end t)
          (let ((start (point)))
            (re-search-forward "^@end lisp")
            (push (string-trim
                   (replace-regexp-in-string
                    "@\\([{}@]\\)" "\\1"
                    (buffer-substring start (line-beginning-position))))
                  out))))
      (nreverse out))))

(ert-deftest cmacs-gowl-hotkey-test-docs-in-sync ()
  "Every cookbook recipe is in the org manual and the Info manual, as
written in the examples file; and every Elisp block the cookbook
sections show is a recipe."
  (let ((org (cmacs-gowl-hotkey-tests--source-file "doc_org/cmacs/gowl.org"))
        (texi (cmacs-gowl-hotkey-tests--source-file "doc/cmacs/cmacs.texi")))
    (skip-unless (and org texi))
    (let ((recipes (mapcar #'cdr (cmacs-gowl-hotkey-tests--recipes)))
          (org-blocks (cmacs-gowl-hotkey-tests--org-blocks org))
          (texi-blocks (cmacs-gowl-hotkey-tests--texi-blocks texi)))
      (should (>= (length recipes) 10))
      (dolist (r recipes)
        (ert-info ((substring r 0 (min 60 (length r))) :prefix "recipe: ")
          (should (member r org-blocks))
          (should (member r texi-blocks))))
      (dolist (b org-blocks)
        (ert-info ((substring b 0 (min 60 (length b))) :prefix "org block: ")
          (should (member b recipes)))))))

;;;; The C surfaces

(ert-deftest cmacs-gowl-hotkey-test-dbus-source ()
  "D-Bus Hotkey is on the compositor interface, checks its verb against
a fixed list and escapes its arguments before building Lisp."
  (let ((iface (cmacs-gowl-hotkey-tests--source-file
                "cmacs/dbus/cmacs-dbus-iface-compositor.c"))
        (dispatch (cmacs-gowl-hotkey-tests--source-file
                   "cmacs/glib/cmacs-eval-dispatch.c")))
    (skip-unless (and iface dispatch))
    (with-temp-buffer
      (insert-file-contents iface)
      (should (search-forward "<method name='Hotkey'>" nil t))
      (should (search-forward "cmacs_dispatch_gowl_hotkey (verb, args" nil t)))
    (with-temp-buffer
      (insert-file-contents dispatch)
      (should (re-search-forward "^cmacs_dispatch_gowl_hotkey " nil t))
      (let ((body (buffer-substring (point)
                                    (progn (re-search-forward "^}" nil t)
                                           (point)))))
        (should (string-match-p "g_strv_contains (verbs, verb)" body))
        (should (string-match-p "cmacs_dispatch_lisp_escape (args)" body))
        (should (string-match-p "strpbrk (args" body))
        (should (string-match-p "cmacs-gowl-hotkey-rpc" body))
        ;; through Elisp: no gowl call here, so no lock to take
        (should-not (string-match-p "gowl_compositor_" body))))))

(ert-deftest cmacs-gowl-hotkey-test-mcp-source ()
  "The cmacs MCP server registers the hotkey tools, escapes the lines
it splices into Lisp, and checks ids are one word."
  (let ((tools (cmacs-gowl-hotkey-tests--source-file
                "cmacs/mcp/cmacs-mcp-tools-gowl.c")))
    (skip-unless tools)
    (with-temp-buffer
      (insert-file-contents tools)
      (dolist (name '("gowl_hotkey_status" "gowl_hotkey_list"
                      "gowl_hotkey_history" "gowl_hotkey_add"
                      "gowl_hotkey_remove" "gowl_hotkey_set"
                      "gowl_hotkey_send" "gowl_hotkey_fire"))
        (goto-char (point-min))
        (should (search-forward (format "\"%s\"" name) nil t)))
      (goto-char (point-min))
      (should (re-search-forward "^gowl_hotkey_line " nil t))
      (let ((body (buffer-substring (point)
                                    (progn (re-search-forward "^}" nil t)
                                           (point)))))
        (should (string-match-p "cmacs_dispatch_lisp_escape (line)" body))
        (should (string-match-p "cmacs-gowl-hotkey-command" body)))
      (dolist (fn '("handle_gowl_hotkey_remove" "handle_gowl_hotkey_fire"))
        (goto-char (point-min))
        (should (re-search-forward (concat "^" fn " ") nil t))
        (let ((body (buffer-substring (point)
                                      (progn (re-search-forward "^}" nil t)
                                             (point)))))
          (should (string-match-p "gowl_broadcast_word (id)" body)))))))

(ert-deftest cmacs-gowl-hotkey-test-emacsctl-source ()
  "emacsctl has a `compositor hotkey' row calling the D-Bus method."
  (let ((ctl (cmacs-gowl-hotkey-tests--source-file
              "cmacs/emacsctl/ctl-cmd-gowl.c")))
    (skip-unless ctl)
    (with-temp-buffer
      (insert-file-contents ctl)
      (should (search-forward "\"compositor hotkey\"" nil t))
      (should (search-forward "\"Hotkey\", \"s:verb s?:args\"" nil t)))))

(ert-deftest cmacs-gowl-hotkey-test-startup-hook-source ()
  "cmacs-gowl.el starts the hotkey surface opt-in, and the module is not
in cmacs's default module list."
  (let ((el (cmacs-gowl-hotkey-tests--source-file "lisp/cmacs/cmacs-gowl.el"))
        (c (cmacs-gowl-hotkey-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless (and el c))
    (with-temp-buffer
      (insert-file-contents el)
      (should (search-forward "(bound-and-true-p cmacs-gowl-hotkey-enable)" nil t))
      (should (search-forward "(cmacs-gowl-hotkey--on-start)" nil t)))
    (with-temp-buffer
      (insert-file-contents c)
      (when (re-search-forward "cmacs_gowl_load_default_modules" nil t)
        (let ((body (buffer-substring (point)
                                      (progn (re-search-forward "^}" nil t)
                                             (point)))))
          (should-not (string-match-p "\"hotkey\"" body)))))))

;;;; Through the real module, in a second cmacs

(defun cmacs-gowl-hotkey-tests--run-headless (form)
  "Evaluate FORM in a second cmacs on gowl's headless backend.
Return (STATUS . OUTPUT): a private runtime directory, systemd off, no
parent display, pixman, fatal criticals, as the other child-cmacs
tests do it."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file
                   (expand-file-name "cmacs-gowl-hotkey-test-" parent) t))
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
                                  cmacs-gowl-hotkey-tests--this-file)))
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

(defconst cmacs-gowl-hotkey-tests--headless-form
  '(progn
     (defun test-wait (pred)
       (let ((n 0))
         (while (and (not (funcall pred)) (< n 100))
           (sit-for 0.05)
           (setq n (1+ n)))
         (funcall pred)))
     (gowl-start)
     (require 'cmacs-gowl)
     (require 'cmacs-gowl-hotkey)
     (cmacs-gowl--install-hook-bridges)
     ;; Opt-in: starting the compositor loaded no hotkey module
     (when (gowl-run-command "hotkey-status")
       (error "The hotkey module was loaded before anyone asked"))
     (setq cmacs-gowl-hotkey-toast nil)
     ;; Defining a hotkey is a first use
     (defvar test-ran nil)
     (cmacs-gowl-hotkey-define "#!c"
       (lambda () (setq test-ran (list cmacs-gowl-hotkey-current
                                       cmacs-gowl-hotkey-trigger)))
       :description "test")
     (unless (gowl-run-command "hotkey-status")
       (error "Defining a hotkey did not load the module"))
     (let ((h (cl-find "#!c" (cmacs-gowl-hotkey-list)
                       :key (lambda (x) (alist-get 'id x)) :test #'equal)))
       (unless (equal (alist-get 'canonical h) "#!c")
         (error "The module has no hotkey #!c: %S" (cmacs-gowl-hotkey-list))))
     ;; Firing it runs the Elisp, on this thread, through the custom
     ;; action path every custom keybind uses
     (cmacs-gowl-hotkey-fire "#!c")
     (unless (test-wait (lambda () test-ran))
       (error "Firing the hotkey never reached Lisp"))
     (unless (equal test-ran '("#!c" "hotkey"))
       (error "The Elisp ran with %S" test-ran))
     ;; A function YAML calls
     (defvar test-args nil)
     (cmacs-gowl-hotkey-define-function "grab"
       (lambda (&rest args) (setq test-args args)))
     (cmacs-gowl-hotkey-call "grab" "one" "two words")
     (unless (test-wait (lambda () test-args))
       (error "hotkey-call never reached the Elisp function"))
     (unless (equal test-args '("one" "two words"))
       (error "The function got %S" test-args))
     ;; A context: the answer is pushed, the module knows it
     (cmacs-gowl-hotkey-define-context "always" (lambda (_) t))
     (unless (string-match-p "always"
                             (cmacs-gowl-hotkey--command "hotkey-contexts"))
       (error "The Elisp context never reached the module"))
     ;; A section under an id, replaced, then removed
     (cmacs-gowl-hotkey-add-section "t"
       '(:hotkeys [(:id "sec-a" :key "F9" :do (:notify "a"))]))
     (cmacs-gowl-hotkey-add-section "t"
       '(:hotkeys [(:id "sec-b" :key "F9" :do (:notify "b"))]))
     (let ((ids (mapcar (lambda (x) (alist-get 'id x)) (cmacs-gowl-hotkey-list))))
       (unless (and (member "sec-b" ids) (not (member "sec-a" ids)))
         (error "Re-adding a section did not replace it: %S" ids)))
     (cmacs-gowl-hotkey-remove-section "t")
     (when (member "sec-b" (mapcar (lambda (x) (alist-get 'id x))
                                   (cmacs-gowl-hotkey-list)))
       (error "Removing a section left its hotkey"))
     ;; Suspending: the module says so and the state follows
     (cmacs-gowl-hotkey-suspend 1)
     (unless (test-wait (lambda () cmacs-gowl-hotkey--suspended))
       (error "The suspend announcement never reached Lisp"))
     (cmacs-gowl-hotkey-suspend -1)
     (unless (test-wait (lambda () (not cmacs-gowl-hotkey--suspended)))
       (error "The resume announcement never reached Lisp"))
     ;; D-Bus/MCP's entry points
     (unless (string-prefix-p "OK {" (cmacs-gowl-hotkey-rpc "status"))
       (error "rpc status did not answer JSON"))
     (unless (string-prefix-p "ERROR" (cmacs-gowl-hotkey-rpc "fire" "nobody"))
       (error "rpc fire of a missing hotkey did not answer ERROR"))
     (gowl-stop)
     (princ "cmacs-gowl-hotkey: ok\n"))
  "What `cmacs-gowl-hotkey-test-headless' runs in the second cmacs.")

(ert-deftest cmacs-gowl-hotkey-test-headless ()
  "The hotkey module, driven from Elisp in a real compositor.
Not loaded until asked for; an Elisp hotkey fires through the custom
action path, functions and contexts reach the module, sections replace
by id, and the module's announcements reach Lisp."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (let ((d (getenv "XDG_RUNTIME_DIR")))
                 (and d (file-directory-p d))))
  (let* ((result (cmacs-gowl-hotkey-tests--run-headless
                  cmacs-gowl-hotkey-tests--headless-form))
         (status (car result))
         (output (cdr result)))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-match-p "cmacs-gowl-hotkey: ok" output)))))

(provide 'cmacs-gowl-hotkey-tests)

;;; cmacs-gowl-hotkey-tests.el ends here
