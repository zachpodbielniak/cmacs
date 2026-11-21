;;; cmacs-small-families-tools-tests.el --- screensaver, podomation, video and ai_list_models on the capability table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Four small tool families that moved off hand-written C together:
;;
;;   lisp/cmacs/cmacs-screensaver-tools.el   screensaver_*   (8 tools)
;;   lisp/cmacs/cmacs-podomation-tools.el    podomation_*    (8 of 10)
;;   lisp/cmacs/cmacs-video-tools.el         video_list      (1 of 2)
;;   lisp/cmacs/cmacs-ai-models-tools.el     ai_list_models  (1)
;;
;; The C handlers are deleted.  What they published was frozen first
;; (test/cmacs/data/mcp-wire-schema.json, read through
;; cmacs-wire-schema.el), and every tool here must have the frozen name,
;; description, parameters in order, their types and the same required
;; set.  The tools left in C on purpose are named, with the reason, and
;; must NOT be here.
;;
;; The rest is behaviour with the subsystem stubbed: what a body calls,
;; what it refuses before calling anything, and what it answers.
;;
;; Everything runs against a private registry with the C mirror stubbed,
;; so nothing registered here reaches the MCP surface of the Emacs
;; running the tests.

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

;; Special here too: the bindings in the tests below are only dynamic if
;; THIS file's compilation knows these variables are special.
(defvar cmacs-screensaver-configs)
(defvar cmacs-screensaver-wallpaper-config)
(defvar cmacs-screensaver-default-config)

(defconst cmacs-small-families-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, captured at load time.")

(defun cmacs-small-families-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or cmacs-small-families-tests--this-file default-directory)
              "lisp/cmacs/cmacs-podomation-tools.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))


(defmacro cmacs-small-families-tests--with-family (file &rest body)
  "Run BODY with a private registry holding only the tools FILE registers.
FILE is a library name under lisp/cmacs."
  (declare (indent 1) (debug t))
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
       (let ((load-prefer-newer t))
         (load (expand-file-name (concat "lisp/cmacs/" ,file)
                                 (cmacs-small-families-tests--root))
               nil t))
       ,@body)))

(defun cmacs-small-families-tests--check (c-file prefix migrated left-in-c)
  "Assert the registry's tools are C-FILE's PREFIX tools, minus LEFT-IN-C.
C-FILE is the base name of the C file that used to register them, as the
frozen wire schema records it (cmacs-wire-schema.el).  MIGRATED is the
list of names expected here; LEFT-IN-C an alist of (NAME . REASON) for
the ones deliberately not.  Every frozen tool of that file whose name
starts with PREFIX must be in exactly one of the two."
  (let ((names (cl-remove-if-not
                (lambda (name) (string-prefix-p prefix name))
                (cmacs-wire-schema-names c-file))))
    (should (equal (sort (copy-sequence names) #'string<)
                   (sort (append migrated (mapcar #'car left-in-c) nil)
                         #'string<)))
    (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                                 (cmacs-capability-describe))
                         #'string<)
                   (sort (copy-sequence migrated) #'string<)))
    (dolist (name names)
      (let ((entry (cmacs-capability-describe-tool name)))
        (ert-info ((format "tool %s" name))
          (if (assoc name left-in-c)
              (should-not entry)
            (cmacs-wire-schema-should-match name :description t)
            (should (memq 'mcp (plist-get entry :surfaces)))))))))

(defun cmacs-small-families-tests--c-file (name)
  "Return NAME, a C file's base name, when the source tree is here.
The file itself is no longer read: what it published is frozen."
  (and (cmacs-small-families-tests--root) name))


;;;; screensaver_*

(defconst cmacs-small-families-tests--screensaver
  '("screensaver_set_wallpaper" "screensaver_stop_wallpaper"
    "screensaver_list_configs" "screensaver_status" "screensaver_restart"
    "screensaver_pause" "screensaver_resume" "screensaver_set_fps")
  "The C screensaver tools, all of which cmacs-screensaver-tools.el provides.")

(ert-deftest cmacs-screensaver-tools-test-family-matches-c ()
  "Every screensaver tool is the C one: name, description, schema."
  (let ((file (cmacs-small-families-tests--c-file "cmacs-mcp-tools-gowl.c")))
    (skip-unless file)
    (cmacs-small-families-tests--with-family "cmacs-screensaver-tools"
      (cmacs-small-families-tests--check
       file "screensaver_" cmacs-small-families-tests--screensaver nil))))

(defmacro cmacs-small-families-tests--with-screensaver (&rest body)
  "Run BODY with the screensaver functions stubbed.
BODY sees `log', a list of (FUNCTION . ARGS), and `running', which is
what the stubbed `gowl-running-p' answers."
  (declare (indent 0) (debug t))
  `(let ((log nil) (running t)
         (cmacs-screensaver-configs
          '((default . (:module blackhole)) (blackhole-cool . (:module x))))
         (cmacs-screensaver-wallpaper-config nil)
         (cmacs-screensaver-default-config 'default))
     (ignore log running)
     ;; The bodies `require' the subsystem; here it is the stubs below.
     (cl-progv '(features) (list (cons 'cmacs-screensaver features))
       (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) running))
                 ((symbol-function 'cmacs-screensaver-set-wallpaper)
                  (lambda (&rest args) (push (cons 'set args) log) nil))
                 ((symbol-function 'cmacs-screensaver-stop-wallpaper)
                  (lambda (&rest _) (push '(stop) log) nil))
                 ((symbol-function 'cmacs-screensaver-restart)
                  (lambda (&rest _) (push '(restart) log) nil))
                 ((symbol-function 'cmacs-screensaver-pause)
                  (lambda (&rest _) (push '(pause) log) nil))
                 ((symbol-function 'cmacs-screensaver-resume)
                  (lambda (&rest _) (push '(resume) log) nil))
                 ((symbol-function 'cmacs-screensaver-set-fps)
                  (lambda (&rest args) (push (cons 'fps args) log) nil))
                 ((symbol-function 'cmacs-screensaver-status)
                  (lambda (&rest _) '(:running t :fps 30))))
         ,@body))))

(ert-deftest cmacs-screensaver-tools-test-behaviour ()
  "The screensaver tools call what the C's dispatch called, and answer t."
  (skip-unless (cmacs-small-families-tests--root))
  (cmacs-small-families-tests--with-family "cmacs-screensaver-tools"
    (cmacs-small-families-tests--with-screensaver
      (should (equal (cmacs-brigade-call-tool "screensaver_list_configs" nil)
                     "default\nblackhole-cool"))
      (should (equal (cmacs-brigade-call-tool "screensaver_status" "{}")
                     "(:running t :fps 30)"))
      ;; A named config is interned only after its alphabet is checked.
      (should (equal (cmacs-brigade-call-tool
                      "screensaver_set_wallpaper"
                      "{\"config\":\"blackhole-cool\"}")
                     "t"))
      (should (equal (car log) '(set blackhole-cool)))
      ;; No config: the configured default, as the C's second form did.
      (cmacs-brigade-call-tool "screensaver_set_wallpaper" "{}")
      (should (equal (car log) '(set default)))
      (let ((cmacs-screensaver-wallpaper-config 'blackhole-cool))
        (cmacs-brigade-call-tool "screensaver_set_wallpaper" nil)
        (should (equal (car log) '(set blackhole-cool))))
      (setq log nil)
      (dolist (bad '("(kill-emacs)" "a b" "x;y" "'quote"))
        (should (equal (cmacs-brigade-call-tool
                        "screensaver_set_wallpaper"
                        (json-serialize (list :config bad)))
                       (format "Error: invalid screensaver config name: %s"
                               bad))))
      (should-not log)
      (dolist (name '("screensaver_stop_wallpaper" "screensaver_restart"
                      "screensaver_pause" "screensaver_resume"))
        (should (equal (cmacs-brigade-call-tool name "{}") "t")))
      (should (equal (reverse log) '((stop) (restart) (pause) (resume))))
      (should (equal (cmacs-brigade-call-tool "screensaver_set_fps"
                                              "{\"fps\":\"30\"}")
                     "t"))
      (should (equal (car log) '(fps 30)))
      (setq log nil)
      (dolist (bad '(0 241 -5))
        (should (equal (cmacs-brigade-call-tool
                        "screensaver_set_fps" (json-serialize (list :fps bad)))
                       (format "Error: screensaver fps must be 1..240 (got %d)"
                               bad))))
      (should-not log))))

(ert-deftest cmacs-screensaver-tools-test-needs-compositor ()
  "What changes the screen needs a compositor; reading does not."
  (skip-unless (cmacs-small-families-tests--root))
  (cmacs-small-families-tests--with-family "cmacs-screensaver-tools"
    (cmacs-small-families-tests--with-screensaver
      (setq running nil)
      (pcase-dolist (`(,name . ,json)
                     '(("screensaver_set_wallpaper" . "{}")
                       ("screensaver_stop_wallpaper" . "{}")
                       ("screensaver_restart" . "{}")
                       ("screensaver_pause" . "{}")
                       ("screensaver_resume" . "{}")
                       ("screensaver_set_fps" . "{\"fps\":30}")))
        (ert-info (name)
          (should (equal (cmacs-brigade-call-tool name json)
                         "Error: Gowl compositor not running"))
          ;; Destructive, so kept from read-only agents -- and named on
          ;; D-Bus and the CLI all the same.
          (let ((entry (cmacs-capability-describe-tool name)))
            (should (plist-get entry :destructive))
            (should (memq 'dbus (plist-get entry :surfaces)))
            (should (memq 'cli (plist-get entry :surfaces))))))
      (should-not log)
      (should (equal (cmacs-brigade-call-tool "screensaver_status" "{}")
                     "(:running t :fps 30)"))
      (should-not (plist-get (cmacs-capability-describe-tool
                              "screensaver_status")
                             :destructive)))))


;;;; podomation_*

(defconst cmacs-small-families-tests--podomation
  '("podomation_emit_event" "podomation_list_pods" "podomation_stats"
    "podomation_list_modules" "podomation_load_file" "podomation_set_context"
    "podomation_reload" "podomation_control")
  "The C podomation tools cmacs-podomation-tools.el provides.")

(defconst cmacs-small-families-tests--podomation-left-in-c
  '(("podomation_eval_dsl" . "runs caller-supplied DSL: privileged")
    ("podomation_repl_eval" . "runs caller-supplied DSL: privileged"))
  "The C podomation tools deliberately left in C, each with its reason.")

(ert-deftest cmacs-podomation-tools-test-family-matches-c ()
  "Every migrated podomation tool is the C one; the privileged two stay."
  (let ((file (cmacs-small-families-tests--c-file "cmacs-mcp-tools-shell.c")))
    (skip-unless file)
    (cmacs-small-families-tests--with-family "cmacs-podomation-tools"
      (cmacs-small-families-tests--check
       file "podomation_" cmacs-small-families-tests--podomation
       cmacs-small-families-tests--podomation-left-in-c)
      ;; The object parameters are objects, as the C schema says.
      (should (equal (plist-get
                      (cadr (plist-get (cmacs-capability-describe-tool
                                        "podomation_emit_event")
                                       :params))
                      :type)
                     "object")))))

(ert-deftest cmacs-podomation-tools-test-behaviour ()
  "The podomation tools call the DEFUNs with values, and answer as the C did."
  (skip-unless (cmacs-small-families-tests--root))
  (cmacs-small-families-tests--with-family "cmacs-podomation-tools"
    (let ((log nil) (up nil))
      (cl-letf (((symbol-function 'cmacs-podomation-emit-event)
                 (lambda (&rest args) (push (cons 'emit args) log) t))
                ((symbol-function 'cmacs-podomation-set-context)
                 (lambda (&rest args) (push (cons 'context args) log) t))
                ((symbol-function 'cmacs-podomation-load-file)
                 (lambda (&rest args) (push (cons 'load args) log) t))
                ((symbol-function 'cmacs-podomation-reload)
                 (lambda (&rest _) (push '(reload) log) t))
                ((symbol-function 'cmacs-podomation-start)
                 (lambda (&rest _) (setq up t)))
                ((symbol-function 'cmacs-podomation-stop)
                 (lambda (&rest _) (setq up nil)))
                ((symbol-function 'cmacs-podomation-running-p)
                 (lambda (&rest _) up))
                ((symbol-function 'cmacs-podomation-run-pod)
                 (lambda (&rest args) (push (cons 'run args) log) 2))
                ((symbol-function 'cmacs-podomation-list-pods)
                 (lambda (&rest _) '(("backup" . healthy))))
                ((symbol-function 'cmacs-podomation-stats)
                 (lambda (&rest _) '(:events-dispatched 3)))
                ((symbol-function 'cmacs-podomation-list-modules)
                 (lambda (&rest _) '("cmacs" "file"))))
        ;; The data object: string members become (STRING . STRING)
        ;; pairs, in order; anything else is skipped, as in C.
        (should (equal (cmacs-brigade-call-tool
                        "podomation_emit_event"
                        "{\"event\":\"on_save\",\"data\":{\"file\":\"a.org\",\"n\":3,\"who\":\"me\",\"deep\":{\"x\":\"y\"}}}")
                       "\"emitted on_save\""))
        (should (equal (car log)
                       '(emit "on_save" (("file" . "a.org") ("who" . "me")))))
        ;; No data at all is nil, not an error.
        (cmacs-brigade-call-tool "podomation_emit_event"
                                 "{\"event\":\"tick\"}")
        (should (equal (car log) '(emit "tick" nil)))
        ;; The event name is a value: nothing in it is ever evaluated.
        (cmacs-brigade-call-tool
         "podomation_emit_event" "{\"event\":\"x\\\" (kill-emacs) \\\"\"}")
        (should (equal (car log) '(emit "x\" (kill-emacs) \"" nil)))
        (should (equal (cmacs-brigade-call-tool
                        "podomation_set_context"
                        "{\"context\":{\"env\":\"prod\"}}")
                       "\"context set\""))
        (should (equal (car log) '(context (("env" . "prod")))))
        (should (string-match-p
                 "\\`Error: .*missing required argument `context'"
                 (cmacs-brigade-call-tool "podomation_set_context" "{}")))
        (should (string-prefix-p
                 "Error: argument `context' must be an object"
                 (cmacs-brigade-call-tool "podomation_set_context"
                                          "{\"context\":[\"a\"]}")))
        (should (equal (cmacs-brigade-call-tool
                        "podomation_load_file" "{\"file\":\"/tmp/a.pod\"}")
                       "\"loaded /tmp/a.pod\""))
        (should (equal (car log) '(load "/tmp/a.pod")))
        (should (equal (cmacs-brigade-call-tool "podomation_reload" nil)
                       "\"engine reloaded\""))
        ;; The lifecycle, and the C's printed answers.
        (should (equal (cmacs-brigade-call-tool "podomation_control"
                                                "{\"action\":\"status\"}")
                       "\"stopped\""))
        (should (equal (cmacs-brigade-call-tool "podomation_control"
                                                "{\"action\":\"start\"}")
                       "\"engine started\""))
        (should (equal (cmacs-brigade-call-tool "podomation_control"
                                                "{\"action\":\"status\"}")
                       "\"running\""))
        (should (equal (cmacs-brigade-call-tool "podomation_control"
                                                "{\"action\":\"stop\"}")
                       "\"engine stopped\""))
        (should (equal (cmacs-brigade-call-tool
                        "podomation_control"
                        "{\"action\":\"run\",\"pod\":\"backup\"}")
                       "\"ran backup 2\""))
        (should (equal (car log) '(run "backup" nil)))
        (cmacs-brigade-call-tool
         "podomation_control"
         "{\"action\":\"run\",\"pod\":\"backup\",\"event\":\"on_timer\"}")
        (should (equal (car log) '(run "backup" "on_timer")))
        (should (equal (cmacs-brigade-call-tool "podomation_control"
                                                "{\"action\":\"run\"}")
                       "Error: action run needs a pod"))
        (should (equal (cmacs-brigade-call-tool "podomation_control"
                                                "{\"action\":\"explode\"}")
                       "Error: action must be one of: start, stop, status, run"))
        ;; The read-only three: the printed form of a printed form,
        ;; which is what `cmacs_dispatch_eval' made of them.
        (should (equal (cmacs-brigade-call-tool "podomation_list_pods" nil)
                       (prin1-to-string "((\"backup\" . healthy))")))
        (should (equal (cmacs-brigade-call-tool "podomation_stats" nil)
                       (prin1-to-string "(:events-dispatched 3)")))
        (should (equal (cmacs-brigade-call-tool "podomation_list_modules" nil)
                       (prin1-to-string "(\"cmacs\" \"file\")")))))
    ;; What drives the engine is destructive; what reads it is not.
    (dolist (name '("podomation_emit_event" "podomation_set_context"
                    "podomation_load_file" "podomation_reload"
                    "podomation_control"))
      (should (plist-get (cmacs-capability-describe-tool name) :destructive)))
    (dolist (name '("podomation_list_pods" "podomation_stats"
                    "podomation_list_modules"))
      (should-not (plist-get (cmacs-capability-describe-tool name)
                             :destructive)))))


;;;; video_list

(ert-deftest cmacs-video-tools-test-family-matches-c ()
  "`video_list' is the C one; `video_snapshot' returns an image and stays."
  (let ((file (cmacs-small-families-tests--c-file "cmacs-mcp-tools-shell.c")))
    (skip-unless file)
    (cmacs-small-families-tests--with-family "cmacs-video-tools"
      (cmacs-small-families-tests--check
       file "video_" '("video_list")
       '(("video_snapshot" . "returns an image")))
      (cl-letf (((symbol-function 'cmacs-video-list) (lambda (&rest _) '(1 4))))
        (should (equal (cmacs-brigade-call-tool "video_list" nil)
                       "\"(1 4)\""))))))


;;;; ai_list_models

(ert-deftest cmacs-ai-models-tools-test-family-matches-c ()
  "`ai_list_models' has the C tool's name, description and schema."
  (let ((file (cmacs-small-families-tests--c-file "cmacs-mcp-tools-ai.c")))
    (skip-unless file)
    (cmacs-small-families-tests--with-family "cmacs-ai-models-tools"
      (let ((entry (cmacs-capability-describe-tool "ai_list_models")))
        (should entry)
        (cmacs-wire-schema-should-match "ai_list_models" :description t)
        ;; Asynchronous, and like the other `ai_' tools not handed to
        ;; in-process agents.
        (should (plist-get entry :async))
        (should (equal (plist-get entry :surfaces) '(mcp dbus cli)))))))

(ert-deftest cmacs-ai-models-tools-test-child-form-is-constant ()
  "Nothing a caller sends is part of the form the child evaluates."
  (skip-unless (cmacs-small-families-tests--root))
  (cmacs-small-families-tests--with-family "cmacs-ai-models-tools"
    (let ((form (symbol-value 'cmacs-ai-models-tools--child-form))
          (started nil))
      ;; It is readable Lisp that names no provider.
      (should (consp (read form)))
      (should-not (string-match-p "\\_<\\(?:ollama\\|claude\\|gemini\\)\\_>" form))
      (cl-letf (((symbol-function 'cmacs-ai-providers)
                 (lambda (&rest _) '(ollama claude-code)))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq started
                         (list :command (plist-get args :command)
                               :providers
                               (getenv (symbol-value
                                        'cmacs-ai-models-tools--providers-env))
                               :endpoints
                               (getenv (symbol-value
                                        'cmacs-ai-models-tools--endpoints-env))))
                   nil)))
        (let ((reply nil))
          ;; One provider, validated against the real list.
          (cmacs-brigade-call-tool-async
           "ai_list_models" "{\"provider\":\"ollama\"}"
           (lambda (status text) (setq reply (list status text))))
          (should (equal (plist-get started :providers) "ollama"))
          ;; The very same form, whatever was asked.
          (should (equal (car (last (plist-get started :command))) form))
          (should (member "-Q" (plist-get started :command)))
          (should (member "-batch" (plist-get started :command)))
          ;; The endpoints file is private and is where the variable is.
          (should (stringp (plist-get started :endpoints)))
          ;; Every provider when none is named.
          (cmacs-brigade-call-tool-async "ai_list_models" "{}" #'ignore)
          (should (equal (plist-get started :providers) "ollama,claude-code"))
          ;; An unknown name never starts a child, and is not interned.
          (setq started nil)
          (cmacs-brigade-call-tool-async
           "ai_list_models" "{\"provider\":\"zz-no-such-provider-zz\"}"
           (lambda (status text) (setq reply (list status text))))
          (should-not started)
          (should (eq (car reply) 'error))
          (should (string-match-p "Unknown provider" (cadr reply)))
          (should-not (intern-soft "zz-no-such-provider-zz")))))))

(defun cmacs-small-families-tests--finished-process (program)
  "Run PROGRAM to completion and return its (dead) process object."
  (let ((p (start-process "ai-models-test" nil program)))
    (set-process-query-on-exit-flag p nil)
    (while (process-live-p p)
      (accept-process-output p 0.05))
    p))

(ert-deftest cmacs-ai-models-tools-test-answers-from-the-sentinel ()
  "The tool returns at once and answers when the child exits."
  (skip-unless (cmacs-small-families-tests--root))
  (skip-unless (and (executable-find "true") (executable-find "false")))
  (cmacs-small-families-tests--with-family "cmacs-ai-models-tools"
    (pcase-dolist (`(,program ,output ,want)
                   '(("true" "{\"ollama\":[\"qwen3\"]}\n"
                      (ok "{\"ollama\":[\"qwen3\"]}"))
                     ;; Exit 0 with something that is not the object.
                     ("true" "Loading cmacs-ai...\n" error)
                     ("false" "" error)))
      (ert-info ((format "%s %S" program output))
        ;; Run before `make-process' is stubbed: `start-process' is
        ;; built on it.
        (let ((sentinel nil) (out nil) (reply nil)
              (child (cmacs-small-families-tests--finished-process program)))
          (cl-letf (((symbol-function 'cmacs-ai-providers)
                     (lambda (&rest _) '(ollama)))
                    ((symbol-function 'make-process)
                     (lambda (&rest args)
                       (setq sentinel (plist-get args :sentinel)
                             out (plist-get args :buffer))
                       child)))
            (cmacs-brigade-call-tool-async
             "ai_list_models" "{}"
             (lambda (status text) (setq reply (list status text))))
            ;; Started, not answered: nothing waited for the child.
            (should sentinel)
            (should-not reply)
            (with-current-buffer out (insert output))
            (funcall sentinel child "finished\n")
            (if (eq want 'error)
                (progn
                  (should (eq (car reply) 'error))
                  (should (string-match-p "could not list models"
                                          (cadr reply))))
              (should (equal reply want)))
            ;; Answered once; the scratch buffers and file are gone.
            (should-not (buffer-live-p out))
            (let ((first reply))
              (funcall sentinel child "finished\n")
              (should (eq reply first)))))))))

(provide 'cmacs-small-families-tools-tests)

;;; cmacs-small-families-tools-tests.el ends here
