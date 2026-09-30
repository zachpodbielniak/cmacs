;;; cmacs-gowl-macro-tests.el --- Tests for gowl macros from Elisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Elisp half of gowl macros.  Most of it needs no compositor: the
;; settings pushed to the module, loading the module on first use and
;; not before, the command lines built (quoting included), Elisp macros
;; and the form the module calls them back through, fault reporting, and
;; the RPC entry that must never signal.  Those stub the gowl primitives
;; (with &rest arglists, so a changed arity cannot hide behind a stub).
;;
;; The last test runs a second cmacs against gowl's headless backend and
;; drives the real module: an Elisp macro by name, a shipped crispy
;; macro by name, a crashing one contained and reported to the hook.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-macro)
(require 'cmacs-gowl-input-remap)

(defconst cmacs-gowl-macro-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, captured at load time; the source tests resolve from it.")

(defun cmacs-gowl-macro-tests--source-file (relative)
  "RELATIVE inside the cmacs source tree, or nil when not present.
Resolved against this test file (test/cmacs/), so it works from a
worktree too; installed trees ship no C sources."
  (let* ((here cmacs-gowl-macro-tests--this-file)
         (root (and here
                    (expand-file-name "../.." (file-name-directory here))))
         (file (and root (expand-file-name relative root))))
    (and file (file-readable-p file) file)))

(defmacro cmacs-gowl-macro-tests--with-module (replies &rest body)
  "Run BODY with the gowl primitives stubbed.
REPLIES is a function from a command line to the module's reply.  Inside
BODY, `sent' is the list of command lines sent (oldest first),
`enabled' the modules enabled and `configured' the settings pushed."
  (declare (indent 1))
  `(let ((sent nil) (enabled nil) (configured nil)
         (cmacs-gowl-macro--enabled nil)
         (cmacs-gowl-macro--functions (make-hash-table :test #'equal))
         (cmacs-gowl-macro-definitions nil)
         (cmacs-gowl-macro-triggers nil))
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-run-command)
                (lambda (line &rest _)
                  (setq sent (append sent (list line)))
                  (funcall ,replies line)))
               ((symbol-function 'gowl-enable-module)
                (lambda (name &rest _) (push name enabled) t))
               ((symbol-function 'gowl-configure-module)
                (lambda (name alist &rest _)
                  (push (cons name alist) configured) t)))
       ,@body)))

(defun cmacs-gowl-macro-tests--loaded-after (flag)
  "A reply function: no module until FLAG (a cons) has a non-nil car."
  (lambda (line)
    (cond ((not (car flag)) nil)
          ((string-prefix-p "macro-status" line) "OK {\"running\":[]}")
          ((string-prefix-p "macro-define" line) "OK defined")
          ((string-prefix-p "macro-run" line) "OK ran it")
          (t "OK"))))

;;;; Settings

(ert-deftest cmacs-gowl-macro-test-settings ()
  "The options become the module's string settings."
  (let ((cmacs-gowl-macro-directory '("/a" "/b"))
        (cmacs-gowl-macro-timeout 500)
        (cmacs-gowl-macro-max-running 0)
        (cmacs-gowl-macro-stop-key nil)
        (cmacs-gowl-macro-log 'run)
        (cmacs-gowl-macro-log-file nil)
        (cmacs-gowl-macro-triggers '("client-added: tidy" "every 1000: tick"))
        (cmacs-gowl-macro-dbus t))
    (let ((s (cmacs-gowl-macro--settings)))
      (should (equal (cdr (assoc "macro-dir" s)) "/a:/b"))
      (should (equal (cdr (assoc "timeout-ms" s)) "500"))
      ;; at least one may run, whatever the option says
      (should (equal (cdr (assoc "max-running" s)) "1"))
      (should (equal (cdr (assoc "stop-key" s)) "none"))
      (should (equal (cdr (assoc "log" s)) "run"))
      (should (equal (cdr (assoc "log-file" s)) "stderr"))
      (should (equal (cdr (assoc "triggers" s))
                     "client-added: tidy\nevery 1000: tick"))
      (should (equal (cdr (assoc "dbus" s)) "true"))
      ;; every fault comes back to Elisp
      (should (equal (cdr (assoc "on-fault-custom" s))
                     "(cmacs-gowl-macro--fault %n %s)"))))
  ;; no directory option, no macro-dir setting (gowl's own list stands)
  (let ((cmacs-gowl-macro-directory nil))
    (should-not (assoc "macro-dir" (cmacs-gowl-macro--settings))))
  ;; the default stop key is not cmacs's menu key
  (should (equal (default-value 'cmacs-gowl-macro-stop-key)
                 "Super+Alt+Escape")))

;;;; Trigger filters

(ert-deftest cmacs-gowl-macro-test-filter-forms ()
  "Filter forms become the text gowl parses, values quoted for it."
  (should (equal (cmacs-gowl-macro-filter "app-id=x and title=y")
                 "app-id=x and title=y"))
  (should (equal (cmacs-gowl-macro-filter '(app-id "firefox*"))
                 "app-id=\"firefox*\""))
  (should (equal (cmacs-gowl-macro-filter '(clients >= 5)) "clients>=\"5\""))
  (should (equal (cmacs-gowl-macro-filter
                  '(and (app-id "firefox*")
                        (or (title "*YouTube*") (title ~ "(?i)twitch"))
                        (not (floating "true"))))
                 (concat "(app-id=\"firefox*\" and "
                         "(title=\"*YouTube*\" or title~\"(?i)twitch\") and "
                         "not (floating=\"true\"))")))
  ;; a single condition needs no parentheses; `not' always groups
  (should (equal (cmacs-gowl-macro-filter '(or (tag 1))) "tag=\"1\""))
  (should (equal (cmacs-gowl-macro-filter '(not (tag 1))) "not (tag=\"1\")"))
  ;; quotes and backslashes are escaped, nothing else
  (should (equal (cmacs-gowl-macro-filter '(title "a\"b\\c"))
                 "title=\"a\\\"b\\\\c\""))
  ;; refusals, here and not in the compositor's log
  (should-error (cmacs-gowl-macro-filter '(colour "red")) :type 'user-error)
  (should-error (cmacs-gowl-macro-filter '(app-id like "x")) :type 'user-error)
  (should-error (cmacs-gowl-macro-filter '(and)) :type 'user-error)
  (should-error (cmacs-gowl-macro-filter '(not (tag 1) (tag 2)))
                :type 'user-error)
  (should-error (cmacs-gowl-macro-filter 42) :type 'user-error))

(ert-deftest cmacs-gowl-macro-test-documented-example ()
  "The manual's meeting-mode example renders to the text gowl tests.
gowl's test-macro-filter judges exactly this string against a Meet tab
and Zoom's settings window, so the two suites pin one example."
  (let* ((call '(and (or (app-id "zoom*")
                         (title ~ "(?i)jitsi|meet\\.google"))
                     (not (title "*Settings*"))))
         (cmacs-gowl-macro-triggers
          `(("client-added"   ,call "meeting-mode" "on")
            ("client-removed" ,call "meeting-mode" "off"))))
    (should (equal (cmacs-gowl-macro-filter call)
                   (concat "((app-id=\"zoom*\" or "
                           "title~\"(?i)jitsi|meet\\\\.google\") "
                           "and not (title=\"*Settings*\"))")))
    (should (equal (split-string
                    (cdr (assoc "triggers" (cmacs-gowl-macro--settings)))
                    "\n")
                   (list (concat "client-added [((app-id=\"zoom*\" or "
                                 "title~\"(?i)jitsi|meet\\\\.google\") and "
                                 "not (title=\"*Settings*\"))]: "
                                 "meeting-mode on")
                         (concat "client-removed [((app-id=\"zoom*\" or "
                                 "title~\"(?i)jitsi|meet\\\\.google\") and "
                                 "not (title=\"*Settings*\"))]: "
                                 "meeting-mode off"))))))

(ert-deftest cmacs-gowl-macro-test-trigger-lines ()
  "Structured triggers become lines; strings pass through."
  (should (equal (cmacs-gowl-macro-trigger-string
                  "client-added" '(app-id "foot") "tidy-on-map")
                 "client-added [app-id=\"foot\"]: tidy-on-map"))
  (should (equal (cmacs-gowl-macro-trigger-string
                  "every 60000" nil "night")
                 "every 60000: night"))
  (should (equal (split-string-shell-command
                  (cadr (split-string
                         (cmacs-gowl-macro-trigger-string
                          "focus-changed" "arg=x" "type-into" "app-id:foot"
                          "make -j8")
                         ": ")))
                 '("type-into" "app-id:foot" "make -j8")))
  (should-error (cmacs-gowl-macro-trigger-string "bad:event" nil "m")
                :type 'user-error)
  (should-error (cmacs-gowl-macro-trigger-string "e" nil "two words")
                :type 'user-error)
  (let ((cmacs-gowl-macro-triggers
         '("client-added: tidy-on-map"
           ("focus-changed" (or (app-id "mpv") (title ~ "(?i)youtube"))
            "presentation" "on"))))
    (should (equal (cdr (assoc "triggers" (cmacs-gowl-macro--settings)))
                   (concat "client-added: tidy-on-map\n"
                           "focus-changed [(app-id=\"mpv\" or "
                           "title~\"(?i)youtube\")]: presentation on"))))
  (let ((cmacs-gowl-macro-triggers '("two\nlines")))
    (should-error (cmacs-gowl-macro--settings) :type 'user-error)))

(ert-deftest cmacs-gowl-macro-test-filter-test-command ()
  "`cmacs-gowl-macro-filter-test' sends the filter text and parses the reply."
  (cmacs-gowl-macro-tests--with-module
      (lambda (line)
        (if (string-prefix-p "macro-status" line) "OK {}"
          "OK {\"match\":true,\"filter\":\"clients>\\\"1\\\"\",\"fields\":{\"clients\":\"3\"}}"))
    (let ((cmacs-gowl-macro--enabled t))
      (let ((r (cmacs-gowl-macro-filter-test '(clients > 1) "focus-changed")))
        (should (eq (alist-get 'match r) t))
        (should (equal (alist-get 'clients (alist-get 'fields r)) "3"))
        (should (equal (car (last sent))
                       "macro-filter-test --event=focus-changed clients>\"1\""))))))

;;;; Loading on first use

(ert-deftest cmacs-gowl-macro-test-loads-on-first-use ()
  "The module is enabled by the first use, configured, and not reloaded."
  (let ((flag (list nil)))
    (cmacs-gowl-macro-tests--with-module
        (cmacs-gowl-macro-tests--loaded-after flag)
      (cl-letf (((symbol-function 'gowl-enable-module)
                 (lambda (name &rest _)
                   (push name enabled) (setcar flag t) t)))
        (should (equal (cmacs-gowl-macro-run "sort-windows") "ran it"))
        (should (equal enabled '("macro")))
        (should (equal (caar configured) "macro"))
        ;; a second use enables nothing more
        (cmacs-gowl-macro-run "sort-windows")
        (should (equal enabled '("macro")))))))

(ert-deftest cmacs-gowl-macro-test-needs-a-compositor ()
  "Without a running compositor every use says so and loads nothing."
  (cmacs-gowl-macro-tests--with-module (lambda (_) nil)
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (should-error (cmacs-gowl-macro-run "x") :type 'user-error)
      (should-error (cmacs-gowl-macro-ensure) :type 'user-error)
      (should-not enabled)
      (should-not sent))))

(ert-deftest cmacs-gowl-macro-test-on-start-is-opt-in ()
  "Compositor start loads the module only when something is configured."
  (cmacs-gowl-macro-tests--with-module (lambda (_) nil)
    (cmacs-gowl-macro--on-start)
    (should-not enabled)
    (should-not sent))
  (let ((flag (list nil)))
    (cmacs-gowl-macro-tests--with-module
        (cmacs-gowl-macro-tests--loaded-after flag)
      (cl-letf (((symbol-function 'gowl-enable-module)
                 (lambda (name &rest _)
                   (push name enabled) (setcar flag t) t)))
        (let ((cmacs-gowl-macro-triggers '("every 60000: night")))
          (cmacs-gowl-macro--on-start)
          (should (equal enabled '("macro"))))))))

;;;; Command lines

(ert-deftest cmacs-gowl-macro-test-command-lines ()
  "Names and arguments reach the module as the words they were."
  (cmacs-gowl-macro-tests--with-module
      (lambda (line) (if (string-prefix-p "macro-status" line) "OK {}"
                       "OK stopped 2"))
    (let ((cmacs-gowl-macro--enabled t))
      (cmacs-gowl-macro-run "type-into" "app-id:foot" "make -j8\n" "it's")
      (let ((line (car (last sent))))
        (should (string-prefix-p "macro-run --trigger=api -- type-into " line))
        ;; the module shell-parses the line: check it the same way
        (should (equal (split-string-shell-command line)
                       '("macro-run" "--trigger=api" "--" "type-into"
                         "app-id:foot" "make -j8\n" "it's"))))
      (should (= (cmacs-gowl-macro-stop "slow one") 2))
      (should (equal (split-string-shell-command (car (last sent)))
                     '("macro-stop" "slow one")))
      (should (= (cmacs-gowl-macro-stop) 2))
      (should (equal (car (last sent)) "macro-stop")))))

(ert-deftest cmacs-gowl-macro-test-errors-are-user-errors ()
  "An ERROR reply is a `user-error' carrying the module's explanation."
  (cmacs-gowl-macro-tests--with-module
      (lambda (line)
        (if (string-prefix-p "macro-status" line) "OK {}"
          "ERROR crash-demo SIGSEGV and was stopped"))
    (let ((cmacs-gowl-macro--enabled t))
      (let ((err (should-error (cmacs-gowl-macro-run "crash-demo")
                               :type 'user-error)))
        (should (string-match-p "SIGSEGV" (cadr err)))))))

(ert-deftest cmacs-gowl-macro-test-rpc-run-never-signals ()
  "The RPC entry answers ERROR instead of signalling, whatever happens."
  (cmacs-gowl-macro-tests--with-module (lambda (_) nil)
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (should (string-prefix-p "ERROR" (cmacs-gowl-macro-rpc-run
                                         "x" "dbus" nil)))))
  (cmacs-gowl-macro-tests--with-module
      (lambda (line) (if (string-prefix-p "macro-status" line) "OK {}"
                       "ERROR x is held back"))
    (let ((cmacs-gowl-macro--enabled t))
      (should (equal (cmacs-gowl-macro-rpc-run "x" "dbus" '("a b"))
                     "ERROR x is held back"))
      (should (equal (split-string-shell-command (car (last sent)))
                     '("macro-run" "--trigger=dbus" "--" "x" "a b"))))))

;;;; Elisp macros

(ert-deftest cmacs-gowl-macro-test-define-installs-a-custom-alias ()
  "An Elisp macro is a custom alias calling back through --call."
  (let ((flag (list t)))
    (cmacs-gowl-macro-tests--with-module
        (cmacs-gowl-macro-tests--loaded-after flag)
      (cmacs-gowl-macro-define "note" #'ignore)
      (should (member "macro-define note custom (cmacs-gowl-macro--call %n '%a %t)"
                      sent))
      (should (eq (gethash "note" cmacs-gowl-macro--functions) #'ignore))
      ;; bad names and non-functions are refused before anything is sent
      (should-error (cmacs-gowl-macro-define "a b" #'ignore)
                    :type 'user-error)
      (should-error (cmacs-gowl-macro-define "a/b" #'ignore)
                    :type 'user-error)
      (should-error (cmacs-gowl-macro-define "c" 42) :type 'user-error))))

(ert-deftest cmacs-gowl-macro-test-defined-before-the-compositor ()
  "A macro defined before the compositor is installed when it starts."
  (let ((flag (list nil)))
    (cmacs-gowl-macro-tests--with-module
        (cmacs-gowl-macro-tests--loaded-after flag)
      (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
        (cmacs-gowl-macro-define "early" #'ignore)
        (should-not sent))
      (cl-letf (((symbol-function 'gowl-enable-module)
                 (lambda (name &rest _)
                   (push name enabled) (setcar flag t) t)))
        (cmacs-gowl-macro--on-start)
        (should (equal enabled '("macro")))
        (should (cl-some (lambda (l) (string-prefix-p "macro-define early " l))
                         sent))))))

(ert-deftest cmacs-gowl-macro-test-callback-form ()
  "The form the module evaluates calls the function with its arguments.
The module expands `(cmacs-gowl-macro--call %n '%a %t)' with Lisp
string literals; %a is a parenthesised list, which the quote keeps
from being evaluated as a call."
  (let* ((cmacs-gowl-macro--functions (make-hash-table :test #'equal))
         (got nil))
    (puthash "grab" (lambda (&rest args)
                      (setq got (cons cmacs-gowl-macro-trigger args)))
             cmacs-gowl-macro--functions)
    (eval (read "(cmacs-gowl-macro--call \"grab\" '(\"a b\" \"c\\\"d\") \"remap\")")
          t)
    (should (equal got '("remap" "a b" "c\"d")))
    ;; no arguments at all
    (eval (read "(cmacs-gowl-macro--call \"grab\" '() \"ipc\")") t)
    (should (equal got '("ipc")))))

(ert-deftest cmacs-gowl-macro-test-elisp-error-is-a-fault ()
  "An error in an Elisp macro is caught and reported to the hook."
  (let* ((cmacs-gowl-macro--functions (make-hash-table :test #'equal))
         (cmacs-gowl-macro-notify nil)
         (faults nil)
         (cmacs-gowl-macro-fault-functions
          (list (lambda (name what) (push (list name what) faults)))))
    (puthash "bad" (lambda (&rest _) (error "Boom")) cmacs-gowl-macro--functions)
    (cmacs-gowl-macro--call "bad" nil "ipc")
    (should (equal faults '(("bad" "Boom"))))
    ;; a missing macro is a message, not an error
    (cmacs-gowl-macro--call "never-defined" nil "ipc")
    (should (= (length faults) 1))
    ;; a C macro's fault arrives through the on-fault-custom form
    (eval (read "(cmacs-gowl-macro--fault \"crash-demo\" \"SIGSEGV\")") t)
    (should (equal (car faults) '("crash-demo" "SIGSEGV")))
    ;; a broken hook function does not break the report
    (let ((cmacs-gowl-macro-fault-functions
           (list (lambda (&rest _) (error "Hook broke")))))
      (cmacs-gowl-macro--fault "x" "timeout"))))

(ert-deftest cmacs-gowl-macro-test-fault-notifies ()
  "With `cmacs-gowl-macro-notify', a fault is a critical notification."
  (let ((cmacs-gowl-macro-notify t)
        (cmacs-gowl-macro-fault-functions nil)
        (notified nil))
    (cl-letf (((symbol-function 'cmacs-notify)
               (lambda (summary &optional body urgency &rest _)
                 (setq notified (list summary body urgency)))))
      (cmacs-gowl-macro--fault "loop-demo" "timeout")
      (should (string-match-p "loop-demo" (car notified)))
      (should (string-match-p "timeout" (cadr notified)))
      (should (eq (nth 2 notified) 'critical)))))

;;;; The Super+space menu

(ert-deftest cmacs-gowl-macro-test-menu-load ()
  "The menu's `Load macros' row loads the module and reopens on Macros."
  (let ((flag (list nil)))
    (cmacs-gowl-macro-tests--with-module
        (cmacs-gowl-macro-tests--loaded-after flag)
      (cl-letf (((symbol-function 'gowl-enable-module)
                 (lambda (name &rest _)
                   (push name enabled) (setcar flag t) t)))
        (should (eq (cmacs-gowl-macro-menu-load) t))
        (should (equal enabled '("macro")))
        (should (equal (car (last sent)) "menu-open macros"))))))

(ert-deftest cmacs-gowl-macro-test-menu-rows-name-real-functions ()
  "Every `elisp:' row in the shipped Macros submenu calls something real.
A row naming a function that does not exist looks fine and does
nothing when chosen."
  (let ((menu (expand-file-name "deps/gowl/data/menu.yaml"
                                (expand-file-name
                                 "../.." (file-name-directory
                                          cmacs-gowl-macro-tests--this-file)))))
    (skip-unless (file-readable-p menu))
    (with-temp-buffer
      (insert-file-contents menu)
      (should (search-forward "  - id: macros" nil t))
      (let ((end (save-excursion (or (re-search-forward "^  - id: " nil t)
                                     (point-max))))
            (seen 0))
        (while (re-search-forward "elisp: \"(\\(?:call-interactively '\\)?\\([a-z-]+\\)"
                                  end t)
          (setq seen (1+ seen))
          (ert-info ((match-string 1))
            (should (fboundp (intern (match-string 1))))))
        (should (>= seen 3))))))

;;;; Keys and files

(ert-deftest cmacs-gowl-macro-test-bind ()
  "A macro keybind is an ipc-command bind running macro-run."
  (let ((flag (list t)) (bound nil))
    (cmacs-gowl-macro-tests--with-module
        (cmacs-gowl-macro-tests--loaded-after flag)
      (cl-letf (((symbol-function 'gowl-add-keybind)
                 (lambda (&rest args) (setq bound args) t)))
        (cmacs-gowl-macro-bind "Super+s" "sort-windows" "reverse")
        (should (equal (nth 0 bound) "Super+s"))
        (should (eq (nth 1 bound) 'ipc-command))
        (should (equal (split-string-shell-command (nth 2 bound))
                       '("macro-run" "sort-windows" "reverse")))))))

(ert-deftest cmacs-gowl-macro-test-new-file ()
  "`cmacs-gowl-macro-new' writes a macro that has the ABI's shape."
  (let* ((dir (make-temp-file "cmacs-gowl-macro-new-" t))
         (cmacs-gowl-macro-directory dir))
    (unwind-protect
        (save-window-excursion
          (cmacs-gowl-macro-new "my-thing" "Does my thing")
          (let ((text (buffer-string)))
            (should (string-match-p "#include <gowl/gowl.h>" text))
            (should (string-match-p "gowl_macro_run(GowlMacroContext \\*ctx)"
                                    text))
            (should (string-match-p "return \"Does my thing\";" text)))
          (kill-buffer)
          (should-error (cmacs-gowl-macro-new "my-thing" "again")
                        :type 'user-error)
          (should-error (cmacs-gowl-macro-new "a b" "x") :type 'user-error))
      (delete-directory dir t))))

;;;; The input remapper's macro target

(ert-deftest cmacs-gowl-macro-test-remap-macro-target ()
  "(macro NAME [ARGS]) is the remapper's {macro:} target."
  (cl-letf (((symbol-function 'cmacs-gowl-macro-ensure) (lambda (&rest _) t)))
    (let* ((rule (json-parse-string
                  (cmacs-gowl-input-remap-rule-json
                   "pads" :match '(:name "Pad")
                   :map '((KEY_A . (macro sort-windows))
                          (KEY_B . (macro "type-into" "app-id:foot 'ls\\n'"))))
                  :object-type 'alist))
           (map (alist-get 'map rule)))
      (should (equal (alist-get 'KEY_A map) '((macro . "sort-windows"))))
      (should (equal (alist-get 'KEY_B map)
                     '((macro . "type-into")
                       (args . "app-id:foot 'ls\\n'")))))
    (should-error (cmacs-gowl-input-remap-rule-json
                   "p" :match '(:name "Pad") :map '((KEY_A . (macro))))
                  :type 'user-error)
    (should-error (cmacs-gowl-input-remap-rule-json
                   "p" :match '(:name "Pad")
                   :map '((KEY_A . (macro ("a" "b")))))
                  :type 'user-error)))

;;;; D-Bus

(ert-deftest cmacs-gowl-macro-test-dbus-run-macro-source ()
  "RunMacro is on the compositor interface and escapes what it splices.
Every string an RPC surface puts into generated Lisp goes through
`cmacs_dispatch_lisp_escape' -- a name or argument with a quote in it
must not end the literal and become code."
  (let ((iface (cmacs-gowl-macro-tests--source-file
                "cmacs/dbus/cmacs-dbus-iface-compositor.c"))
        (dispatch (cmacs-gowl-macro-tests--source-file
                   "cmacs/glib/cmacs-eval-dispatch.c")))
    (skip-unless (and iface dispatch))
    (with-temp-buffer
      (insert-file-contents iface)
      (should (search-forward "<method name='RunMacro'>" nil t))
      (should (search-forward "cmacs_dispatch_gowl_run_macro (name, args"
                              nil t)))
    (with-temp-buffer
      (insert-file-contents dispatch)
      (should (re-search-forward "^cmacs_dispatch_gowl_run_macro " nil t))
      (let ((body (buffer-substring (point)
                                    (progn (re-search-forward "^}" nil t)
                                           (point)))))
        (should (string-match-p "cmacs_dispatch_lisp_escape (name)" body))
        (should (string-match-p "cmacs_dispatch_lisp_escape (args\\[i\\])"
                                body))
        (should (string-match-p "cmacs-gowl-macro-rpc-run" body))
        ;; no raw %s of an unescaped argument
        (should-not (string-match-p "printf ([^;]*, name)" body))))))

;;;; Through the real module, in a second cmacs

(defun cmacs-gowl-macro-tests--run-headless (form cache)
  "Evaluate FORM in a second cmacs on gowl's headless backend.
Return (STATUS . OUTPUT).  As `cmacs-gowl-tests--run-headless' does it:
a private runtime directory (socket paths are short), systemd off, no
parent display, pixman, fatal criticals, state and config inside the
runtime directory -- plus CACHE for compiled macros, so the user's own
cache is never written, and no GOWL_MACRO_DIR from the environment."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file
                   (expand-file-name "cmacs-gowl-macro-test-" parent) t))
         (default-directory (file-name-as-directory runtime))
         (emacs (expand-file-name invocation-name invocation-directory))
         (timeout (executable-find "timeout"))
         (process-environment
          (append (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                        "GOWL_MACRO_DIR"
                        "GOWL_DISABLE_SYSTEMD=1"
                        (concat "XDG_RUNTIME_DIR=" runtime)
                        (concat "XDG_CONFIG_HOME=" runtime)
                        (concat "XDG_STATE_HOME="
                                (expand-file-name "state" runtime))
                        (concat "XDG_CACHE_HOME=" cache)
                        ;; this tree's menu, not an installed older one
                        (concat "GOWL_MENU_FILE="
                                (expand-file-name
                                 "../../deps/gowl/data/menu.yaml"
                                 (file-name-directory
                                  cmacs-gowl-macro-tests--this-file)))
                        "WLR_BACKENDS=headless"
                        "WLR_HEADLESS_OUTPUTS=1"
                        "WLR_RENDERER=pixman"
                        "G_DEBUG=fatal-criticals")
                  process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (or timeout emacs) nil t nil
                               (append (and timeout (list "180" emacs))
                                       (list "--batch" "-Q" "--eval"
                                             "(setq backtrace-on-error-noninteractive nil)"
                                             "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(defconst cmacs-gowl-macro-tests--headless-form
  '(progn
     (defvar test-ran nil)
     (defvar test-fault nil)
     (defun test-wait (pred)
       (let ((n 0))
         (while (and (not (funcall pred)) (< n 100))
           (sit-for 0.05)
           (setq n (1+ n)))
         (funcall pred)))
     (gowl-start)
     (require 'cmacs-gowl-macro)
     (require 'seq)
     ;; Opt-in: starting the compositor loaded no macro module
     (when (gowl-run-command "macro-status")
       (error "The macro module was loaded before anyone asked"))
     ;; ... so the menu's Macros submenu offers only `Load macros'
     (when (fboundp 'gowl-menu-items)
       (let ((rows (gowl-menu-items "macros")))
         (unless (and (= (length rows) 1)
                      (equal (plist-get (car rows) :label) "Load macros")
                      (not (plist-get (car rows) :disabled)))
           (error "Macros submenu before loading: %S" rows))))
     (setq cmacs-gowl-macro-notify nil)
     (add-hook 'cmacs-gowl-macro-fault-functions
               (lambda (name what) (setq test-fault (list name what))))
     ;; An Elisp macro: defining it is a first use
     (cmacs-gowl-macro-define
      "elisp-hello"
      (lambda (&rest args)
        (setq test-ran (cons cmacs-gowl-macro-trigger args))))
     (unless (gowl-run-command "macro-status")
       (error "Defining a macro did not load the module"))
     (cmacs-gowl-macro-run "elisp-hello" "a b" "c\"d")
     (unless (test-wait (lambda () test-ran))
       (error "The Elisp macro never ran"))
     (unless (equal test-ran '("api" "a b" "c\"d"))
       (error "The Elisp macro got %S" test-ran))
     ;; ... and from the module's own IPC word, as a keybind would
     (setq test-ran nil)
     (gowl-run-command "macro-run elisp-hello x")
     (unless (and (test-wait (lambda () test-ran))
                  (equal test-ran '("ipc" "x")))
       (error "Via IPC the Elisp macro got %S" test-ran))
     ;; The menu now lists the macros, Elisp ones included, and choosing
     ;; one runs it
     (when (fboundp 'gowl-menu-items)
       (let* ((rows (gowl-menu-items "macros"))
              (mine (seq-find (lambda (r)
                                (equal (plist-get r :label) "elisp-hello"))
                              rows)))
         (when (seq-find (lambda (r)
                           (equal (plist-get r :label) "Load macros"))
                         rows)
           (error "`Load macros' is still offered once loaded"))
         (unless (seq-find (lambda (r) (equal (plist-get r :label) "hello"))
                           rows)
           (error "The shipped hello is not in the Macros submenu"))
         (unless (and mine (equal (plist-get mine :detail) "Elisp"))
           (error "The Elisp macro's row: %S" mine))
         (setq test-ran nil)
         (gowl-menu-activate (plist-get mine :route))
         (unless (and (test-wait (lambda () test-ran))
                      (equal test-ran '("ipc")))
           (error "Chosen from the menu, the Elisp macro got %S" test-ran))))
     ;; A shipped crispy macro by name
     (let ((reply (cmacs-gowl-macro-run "hello" "world")))
       (unless (equal reply "hello: hello")
         (error "hello said %S" reply)))
     (unless (assoc "hello" (mapcar (lambda (m)
                                      (cons (alist-get 'name m) m))
                                    (cmacs-gowl-macro-list)))
       (error "hello is not listed"))
     ;; A crash: contained, refused, reported to the hook
     (let ((err (condition-case e (progn (cmacs-gowl-macro-run "crash-demo")
                                         nil)
                  (user-error (cadr e)))))
       (unless (and err (string-match-p "SIGSEGV" err))
         (error "crash-demo was not stopped: %S" err)))
     (unless (and (test-wait (lambda () test-fault))
                  (equal test-fault '("crash-demo" "SIGSEGV")))
       (error "The fault hook got %S" test-fault))
     (unless (string-match-p "held back"
                             (cmacs-gowl-macro-rpc-run "crash-demo" "dbus"
                                                       nil))
       (error "crash-demo was not held back"))
     (cmacs-gowl-macro-clear "crash-demo")
     ;; An Elisp macro that signals is a fault too
     (setq test-fault nil)
     (cmacs-gowl-macro-define "elisp-bad" (lambda (&rest _) (error "Boom")))
     (cmacs-gowl-macro-run "elisp-bad")
     (unless (and (test-wait (lambda () test-fault))
                  (equal test-fault '("elisp-bad" "Boom")))
       (error "An Elisp error reached the hook as %S" test-fault))
     ;; Filtered triggers, structured, as the module understood them
     (setq cmacs-gowl-macro-triggers
           '(("layout-changed" (and (arg "[M]") (not (monitor "NONE")))
              "hello" "filtered")
             "layout-changed [clients>=0 or tag=1]: hello"
             "layout-changed [nosuchfield=1]: hello"))
     (cmacs-gowl-macro-configure)
     (let* ((tr (cmacs-gowl-macro-list-triggers))
            (lines (alist-get 'triggers tr)))
       (unless (and (= (alist-get 'errors tr) 1) (= (length lines) 2))
         (error "Triggers after configure: %S" tr))
       (unless (equal (alist-get 'filter (car lines))
                      "(arg=\"[M]\" and not monitor=\"NONE\")")
         (error "The structured filter was read as %S"
                (alist-get 'filter (car lines)))))
     (let ((r (cmacs-gowl-macro-filter-test '(and (clients >= 0) (hour >= 0))
                                            "focus-changed")))
       (unless (eq (alist-get 'match r) t)
         (error "filter-test: %S" r))
       (unless (equal (alist-get 'event (alist-get 'fields r))
                      "focus-changed")
         (error "filter-test fields: %S" r)))
     (cmacs-gowl-macro-disable)
     (when (gowl-run-command "macro-status")
       (error "Still answering after disable"))
     (gowl-stop)
     (princ "cmacs-gowl-macro: ok\n"))
  "What `cmacs-gowl-macro-test-headless' runs in the second cmacs.")

(ert-deftest cmacs-gowl-macro-test-headless ()
  "The macro module, driven from Elisp in a real compositor.
Not loaded until asked for; an Elisp macro runs by name from Elisp and
from IPC with its arguments and trigger; a shipped crispy macro runs by
name; a crash is contained, held back and reaches the fault hook; an
Elisp error does too."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (let ((d (getenv "XDG_RUNTIME_DIR")))
                 (and d (file-directory-p d))))
  (let* ((cache (make-temp-file "cmacs-gowl-macro-cache-" t))
         (result (unwind-protect
                     (cmacs-gowl-macro-tests--run-headless
                      cmacs-gowl-macro-tests--headless-form cache)
                   (delete-directory cache t)))
         (status (car result))
         (output (cdr result)))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-match-p "cmacs-gowl-macro: ok" output)))))

(provide 'cmacs-gowl-macro-tests)

;;; cmacs-gowl-macro-tests.el ends here
