;;; cmacs-gowl-macro.el --- gowl macros from Elisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `macro' module runs *macros*: small C files, compiled at run
;; time with crispy and loaded into the compositor, that sort windows,
;; type into one named window while another keeps focus, move windows
;; between tags -- anything the gowl API can do.  Every call into one
;; runs under a fault guard and a watchdog, so a macro that crashes or
;; loops forever is stopped, reported and held back instead of taking
;; the desktop with it.  This file is the Elisp surface under
;; `cmacs --gowl'.
;;
;; NOTHING IS LOADED BY DEFAULT.  The module is opt-in, and it is
;; enabled the first time any function here is used -- or at compositor
;; start when you have configured something for it (an Elisp macro in
;; `cmacs-gowl-macro-definitions', a trigger in
;; `cmacs-gowl-macro-triggers').  The three default keys reach it
;; through functions here, so pressing one is a first use:
;;
;;   Super+Alt+r         `cmacs-gowl-macro-record': record what you do
;;                       next; press again to stop.  It is written out
;;                       as last-recording.c (`C-u' to name it).
;;   Super+Alt+Shift+r   `cmacs-gowl-macro-replay': play it back.
;;   Super+Alt+m         `cmacs-gowl-macro-voice': say a macro's name;
;;                       cmacs's own whisper transcribes it.
;;
;; Two kinds of macro:
;;
;; - C files in the normal gowl places (~/.config/gowl/macros,
;;   /usr/share/gowl/macros, `cmacs-gowl-macro-directory', ...), run by
;;   name: (cmacs-gowl-macro-run "sort-windows" "reverse").  gowl ships
;;   25 commented examples; M-x cmacs-gowl-macro-list-macros shows them.
;;
;; - Elisp functions, given a name every trigger can use:
;;
;;     (cmacs-gowl-macro-define "note"
;;       (lambda (&rest _) (org-capture nil "n")))
;;
;;   Now `gowl-msg macro-run note', a gowl keybind, a D-Bus call, a foot
;;   pedal through the input remapper, or another macro all run it.  The
;;   function runs on Emacs's main thread, never the compositor's: the
;;   module fires a `custom' action whose form calls back in here
;;   through the same idle dispatch every custom keybind uses.
;;
;; Crispy macros never call Lisp directly -- they run in the compositor.
;; Give the Elisp half a name with `cmacs-gowl-macro-define' and have
;; the C half run it by that name.
;;
;; Everything goes through `gowl-run-command' and the module's `macro-'
;; words, the same ones the IPC socket, MCP and D-Bus reach.  See the
;; "Macros" section of the gowl chapter in the cmacs manual and
;; deps/gowl/docs/macros.org.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)

(declare-function gowl-run-command "cmacs-gowl")
(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-enable-module "cmacs-gowl")
(declare-function gowl-disable-module "cmacs-gowl")
(declare-function gowl-configure-module "cmacs-gowl")
(declare-function gowl-add-keybind "cmacs-gowl")
(declare-function cmacs-notify "cmacs-notify")
(declare-function cmacs-audio--capture-open-1 "cmacs-audio")
(declare-function cmacs-audio-start "cmacs-audio")
(declare-function cmacs-audio-close "cmacs-audio")
(declare-function cmacs-audio-read-pcm "cmacs-audio")
(declare-function cmacs-whisper-model-path "cmacs-whisper")
(declare-function cmacs-whisper-transcribe-pcm-async "cmacs-whisper")
(defvar cmacs-audio-capture-source)
(defvar cmacs-audio-default-rate)
(defvar cmacs-audio-default-device)
(defvar cmacs-whisper-language)

(defgroup cmacs-gowl-macro nil
  "gowl macros: guarded crispy C scripts, and Elisp by name."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-macro-")

(defcustom cmacs-gowl-macro-directory nil
  "A directory searched for macro files before gowl's standard ones.
nil searches only gowl's own list (~/.config/gowl/macros,
$XDG_DATA_HOME/gowl/macros, /etc/gowl/macros, /usr/local/share/gowl/macros,
/usr/share/gowl/macros).  A list of directories is searched in order."
  :type '(choice (const :tag "Only gowl's directories" nil)
                 directory
                 (repeat directory))
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-timeout 2000
  "Milliseconds a macro may run before the watchdog stops it.
A macro may raise its own budget; 0 switches the watchdog off."
  :type 'natnum
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-max-running 4
  "How many macros may run at once."
  :type 'natnum
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-stop-key "Super+Alt+Escape"
  "The gowl key that stops every running macro, or nil for none.
Consumed only while a macro runs.  gowl's own default, Super+Escape,
is cmacs's menu key, and configured keybinds win over the module's."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-log 'fault
  "What the macro module logs: `none', `fault', `run' or `all'."
  :type '(choice (const none) (const fault) (const run) (const all))
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-log-file nil
  "Where the macro module logs; nil for stderr."
  :type '(choice (const :tag "stderr" nil) file)
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-triggers nil
  "Event and timer triggers.  Setting this loads the module at start.
Each entry is either a string, as gowl reads it,

  \"EVENT [FILTER]: MACRO [ARGS]\"   or   \"every MS [FILTER]: MACRO [ARGS]\"

or a list (EVENT FILTER MACRO ARG...), where EVENT is a string
\(\"client-added\", \"focus-changed\", \"every 60000\", ...), FILTER is
nil, a filter string, or a filter form (see `cmacs-gowl-macro-filter'),
and MACRO and each ARG are strings.  Only the triggers whose filter
matches the event run; several may name one event."
  :type '(repeat (choice string
                         (cons :tag "Structured"
                               (string :tag "Event")
                               (cons (sexp :tag "Filter")
                                     (repeat :tag "Macro and arguments"
                                             string)))))
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-dbus nil
  "Non-nil to have the module own org.gowl.Macro1 on the session bus.
cmacs's own org.cmacs.Editor1.Compositor.RunMacro works either way."
  :type 'boolean
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-definitions nil
  "Elisp macros installed whenever the module is enabled.
An alist of (NAME . FUNCTION); see `cmacs-gowl-macro-define'.  Setting
this loads the module at compositor start."
  :type '(alist :key-type string :value-type function)
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-notify t
  "Non-nil to raise a desktop notification when a macro faults.
gowl's bar shows a toast on its own; this adds a D-Bus notification
through `cmacs-notify' and a line in *Messages*."
  :type 'boolean
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-fault-functions nil
  "Abnormal hook run when a macro faults or an Elisp macro signals.
Each function is called with NAME and WHAT: the signal name
\(\"SIGSEGV\", \"timeout\", ...) for a C macro, or the error message
for an Elisp one."
  :type 'hook
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-voice-max-seconds 10
  "Stop listening after this many seconds, as if the voice key were
pressed again.  Also the module's `voice-max-seconds'."
  :type 'integer
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-voice-phrases nil
  "Spoken phrases for macros, checked before macro names.
An alist of (PHRASE . \"MACRO ARGS\"): (\"tidy up\" . \"sort-windows\")
makes saying \"tidy up\" run `sort-windows'.  Words said after the
phrase are added as arguments.  Without an entry a macro is still
reached by saying its name: `pip-corner' is \"pip corner\"."
  :type '(alist :key-type string :value-type string)
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-voice-command nil
  "The module's `voice-command', for the `command' backend.
A shell command that listens until SIGINT and prints what it heard.
nil leaves the module's default, gowl-stt."
  :type '(choice (const :tag "gowl-stt" nil) string)
  :group 'cmacs-gowl-macro)

(defcustom cmacs-gowl-macro-voice-backend 'whisper
  "How `cmacs-gowl-macro-voice' listens.
`whisper' records with cmacs's audio subsystem and transcribes with its
embedded whisper.cpp -- no extra program.  `command' leaves it to the
module's `voice-command' (gowl-stt by default), as standalone gowl
does.  `whisper' falls back to `command' in a cmacs built without the
audio or whisper subsystems."
  :type '(choice (const whisper) (const command))
  :group 'cmacs-gowl-macro)

(defconst cmacs-gowl-macro--module "macro"
  "The gowl module this file drives.")

(defvar cmacs-gowl-macro--functions (make-hash-table :test #'equal)
  "Elisp macros defined this session: NAME -> FUNCTION.
Re-installed whenever the module is enabled, so a macro defined in the
init file before `cmacs-gowl-mode' is not lost.")

(defvar cmacs-gowl-macro--enabled nil
  "Non-nil once the module has been enabled in this compositor.")

(defvar cmacs-gowl-macro-trigger nil
  "While an Elisp macro runs: what started it, as a string.
\"ipc\", \"dbus\", \"event\", \"timer\", \"remap\" or \"api\".")

;;;; Talking to the module

(defun cmacs-gowl-macro--running-p ()
  "Non-nil when a gowl compositor is running in this Emacs."
  (and (fboundp 'gowl-running-p) (gowl-running-p)))

(defun cmacs-gowl-macro--reply (reply)
  "The text of module REPLY after \"OK \"; signal on \"ERROR\"."
  (cond ((null reply)
         (user-error "The gowl macro module is not loaded"))
        ((string-prefix-p "ERROR" reply)
         (user-error "Macro: %s" (string-trim (substring reply 5))))
        ((string-prefix-p "OK " reply) (substring reply 3))
        ((equal reply "OK") "")
        (t reply)))

(defun cmacs-gowl-macro--command (line)
  "Enable the module if need be, run LINE, and return its OK text."
  (cmacs-gowl-macro-ensure)
  (cmacs-gowl-macro--reply (gowl-run-command line)))

(defun cmacs-gowl-macro-command (line)
  "Run the macro module's command LINE, loading the module first.
Returns the reply without its \"OK \"; an \"ERROR\" reply is a
`user-error'.  The general form the MCP tools and other callers use:
\"macro-list\", \"macro-status\", \"macro-voice status\", ..."
  (cmacs-gowl-macro--command line))

(defun cmacs-gowl-macro--json (line)
  "Run LINE and parse its JSON reply into alists."
  (json-parse-string (cmacs-gowl-macro--command line)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun cmacs-gowl-macro--quote (arg)
  "ARG as one shell word, for a module command line."
  (shell-quote-argument (format "%s" arg)))

(defun cmacs-gowl-macro--dirs ()
  "`cmacs-gowl-macro-directory' as a `:'-separated string, or nil."
  (let ((dirs (if (listp cmacs-gowl-macro-directory)
                  cmacs-gowl-macro-directory
                (list cmacs-gowl-macro-directory))))
    (and dirs
         (mapconcat (lambda (d) (expand-file-name d)) dirs ":"))))

(defun cmacs-gowl-macro--settings ()
  "The module settings, as the string alist `gowl-configure-module' takes."
  (let ((dirs (cmacs-gowl-macro--dirs)))
    (append
     (and dirs (list (cons "macro-dir" dirs)))
     (list (cons "timeout-ms" (number-to-string cmacs-gowl-macro-timeout))
           (cons "max-running"
                 (number-to-string (max 1 cmacs-gowl-macro-max-running)))
           (cons "stop-key" (or cmacs-gowl-macro-stop-key "none"))
           (cons "log" (symbol-name cmacs-gowl-macro-log))
           (cons "log-file" (if cmacs-gowl-macro-log-file
                                (expand-file-name cmacs-gowl-macro-log-file)
                              "stderr"))
           (cons "triggers" (mapconcat #'cmacs-gowl-macro--trigger-line
                                       cmacs-gowl-macro-triggers "\n"))
           (cons "dbus" (if cmacs-gowl-macro-dbus "true" "false"))
           ;; Recordings land where `cmacs-gowl-macro-new' writes, so
           ;; the list and `cmacs-gowl-macro-visit' find them.
           (cons "record-dir" (cmacs-gowl-macro--new-dir))
           (cons "voice-command" (or cmacs-gowl-macro-voice-command ""))
           (cons "voice-max-seconds"
                 (number-to-string (max 1 cmacs-gowl-macro-voice-max-seconds)))
           (cons "voice-phrases"
                 (mapconcat (lambda (p) (format "%s: %s" (car p) (cdr p)))
                            cmacs-gowl-macro-voice-phrases "\n"))
           ;; Every fault reaches Elisp: the module Lisp-quotes %n/%s
           (cons "on-fault-custom" "(cmacs-gowl-macro--fault %n %s)")))))

;;;###autoload
(defun cmacs-gowl-macro-ensure ()
  "Load and enable gowl's `macro' module if it is not already.
Pushes the settings and installs the Elisp macros defined this session.
Every function here calls this first, which is what makes the module
load on first use.  Returns t."
  (unless (cmacs-gowl-macro--running-p)
    (user-error "Gowl compositor is not running"))
  (unless (and cmacs-gowl-macro--enabled
               (gowl-run-command "macro-status"))
    (unless (gowl-run-command "macro-status")
      (gowl-enable-module cmacs-gowl-macro--module))
    (condition-case err
        (gowl-configure-module cmacs-gowl-macro--module
                               (cmacs-gowl-macro--settings))
      (error (message "cmacs-gowl-macro: settings failed: %s"
                      (error-message-string err))))
    (setq cmacs-gowl-macro--enabled t)
    (dolist (def cmacs-gowl-macro-definitions)
      (puthash (car def) (cdr def) cmacs-gowl-macro--functions))
    (maphash (lambda (name _fn)
               (condition-case err
                   (cmacs-gowl-macro--install name)
                 (error (message "cmacs-gowl-macro: %s: %s" name
                                 (error-message-string err)))))
             cmacs-gowl-macro--functions))
  t)

;;;###autoload
(defun cmacs-gowl-macro-configure ()
  "Push the current `cmacs-gowl-macro-' settings to the module."
  (interactive)
  (cmacs-gowl-macro-ensure)
  (gowl-configure-module cmacs-gowl-macro--module
                         (cmacs-gowl-macro--settings))
  (when (called-interactively-p 'interactive)
    (message "Macro settings applied")))

;;;###autoload
(defun cmacs-gowl-macro-disable ()
  "Disable the `macro' module: running macros stop, triggers go quiet.
Elisp macros stay defined and come back with the next use."
  (interactive)
  (when (cmacs-gowl-macro--running-p)
    (gowl-disable-module cmacs-gowl-macro--module))
  (setq cmacs-gowl-macro--enabled nil))

;;;; Running

(defun cmacs-gowl-macro--names ()
  "Every macro runnable by name, for completion."
  (condition-case nil
      (mapcar (lambda (m) (alist-get 'name m)) (cmacs-gowl-macro-list))
    (error nil)))

(defun cmacs-gowl-macro--read-name (prompt)
  "Read a macro name with completion over the runnable ones."
  (completing-read prompt (cmacs-gowl-macro--names) nil nil))

;;;###autoload
(defun cmacs-gowl-macro-run (name &rest args)
  "Run the gowl macro NAME with ARGS (strings) and return its reply.
NAME is a file on the macro search path (\"sort-windows\" or
\"sort-windows.c\"), a full path, or a macro defined here or
registered from C.  The reply is the macro's result, or \"started
NAME id=N ...\" when it queued timed steps or runs on a worker.
A macro that faults signals a `user-error' carrying why.

Interactively, prompt for the name, then for arguments."
  (interactive
   (let ((name (cmacs-gowl-macro--read-name "Run macro: ")))
     (cons name (split-string-shell-command
                 (read-string (format "Arguments for %s: " name))))))
  (let ((reply (cmacs-gowl-macro--command
                (mapconcat #'identity
                           (append (list "macro-run --trigger=api --"
                                         (cmacs-gowl-macro--quote name))
                                   (mapcar #'cmacs-gowl-macro--quote args))
                           " "))))
    (when (called-interactively-p 'interactive)
      (message "Macro: %s" reply))
    reply))

;;;###autoload
(defun cmacs-gowl-macro-rpc-run (name trigger args)
  "Run macro NAME with ARGS for an RPC surface; return the reply line.
TRIGGER (\"dbus\", \"api\", ...) is what the macro sees as its trigger.
Never signals: a failure comes back as \"ERROR ...\", the way the
module itself answers.  Behind org.cmacs.Editor1.Compositor.RunMacro."
  (condition-case err
      (progn
        (cmacs-gowl-macro-ensure)
        (or (gowl-run-command
             (mapconcat #'identity
                        (append (list (concat "macro-run --trigger="
                                              (cmacs-gowl-macro--quote trigger)
                                              " --")
                                      (cmacs-gowl-macro--quote name))
                                (mapcar #'cmacs-gowl-macro--quote args))
                        " "))
            "ERROR the gowl macro module is not loaded"))
    (error (concat "ERROR " (error-message-string err)))))

;;;###autoload
(defun cmacs-gowl-macro-stop (&optional which)
  "Stop running macros: WHICH is a name, a run id, or nil for all.
Return how many were told to stop."
  (interactive)
  (let* ((reply (cmacs-gowl-macro--command
                 (if which
                     (concat "macro-stop " (cmacs-gowl-macro--quote which))
                   "macro-stop")))
         (n (and (string-match "stopped \\([0-9]+\\)" reply)
                 (string-to-number (match-string 1 reply)))))
    (when (called-interactively-p 'interactive)
      (message "Macro: %s" reply))
    n))

(defun cmacs-gowl-macro-list ()
  "Every macro runnable by name, as alists (name, kind, path, held-back)."
  (cmacs-gowl-macro--json "macro-list"))

(defun cmacs-gowl-macro-status ()
  "The module's status as an alist: running, held-back, faults, ..."
  (cmacs-gowl-macro--json "macro-status"))

(defun cmacs-gowl-macro-info (name)
  "What the module knows of macro NAME, as an alist."
  (cmacs-gowl-macro--json (concat "macro-info "
                                  (cmacs-gowl-macro--quote name))))

;;;###autoload
(defun cmacs-gowl-macro-clear (&optional name)
  "Let NAME run again after a fault held it back; nil clears all."
  (interactive
   (list (let ((held (mapcar (lambda (h) (alist-get 'name h))
                             (alist-get 'held-back
                                        (cmacs-gowl-macro-status)))))
           (if held
               (completing-read "Clear macro (empty for all): " held)
             (user-error "No macro is held back")))))
  (let ((reply (cmacs-gowl-macro--command
                (if (and name (not (string-empty-p name)))
                    (concat "macro-clear " (cmacs-gowl-macro--quote name))
                  "macro-clear"))))
    (when (called-interactively-p 'interactive)
      (message "Macro: %s" reply))
    reply))

;;;###autoload
(defun cmacs-gowl-macro-compile (name)
  "Compile macro NAME without running it; signal its compile error."
  (interactive (list (cmacs-gowl-macro--read-name "Compile macro: ")))
  (let ((reply (cmacs-gowl-macro--command
                (concat "macro-compile " (cmacs-gowl-macro--quote name)))))
    (when (called-interactively-p 'interactive)
      (message "Macro: %s" reply))
    reply))

;;;###autoload
(defun cmacs-gowl-macro-reload ()
  "Forget compiled macros and re-read the triggers."
  (interactive)
  (let ((reply (cmacs-gowl-macro--command "macro-reload")))
    (when (called-interactively-p 'interactive)
      (message "Macro: %s" reply))
    reply))

;;;; Trigger filters

(defconst cmacs-gowl-macro--filter-ops
  '(= != ~ !~ < <= > >=)
  "The comparison operators a filter form may name.")

(defconst cmacs-gowl-macro--filter-fields
  '(event app-id title floating fullscreen urgent xwayland
          focused-app-id focused-title monitor layout tag tags clients
          arg time hour weekday)
  "Every field gowl can test (mirrors gowl-macro-filter.c).")

(defun cmacs-gowl-macro--filter-value (v)
  "V as a quoted filter value: `\"' and `\\' escaped, nothing else."
  (let ((s (if (stringp v) v (format "%s" v))))
    (concat "\""
            (replace-regexp-in-string "[\"\\]" "\\\\\\&" s)
            "\"")))

(defun cmacs-gowl-macro-filter (form)
  "The gowl trigger filter text for FORM.
FORM is a string (used as it is), or a list:

  (and FORM...)   (or FORM...)   (not FORM)
  (FIELD VALUE)            glob match, e.g. (app-id \"firefox*\")
  (FIELD OP VALUE)         OP is one of = != ~ !~ < <= > >=

FIELD is a symbol from `cmacs-gowl-macro--filter-fields'.  Values are
quoted for you, so any string is safe.  For example

  (and (app-id \"firefox*\")
       (or (title \"*YouTube*\") (title ~ \"(?i)twitch\"))
       (not (floating \"true\")))

An unknown field or operator is a `user-error' here rather than a
refused trigger in the compositor's log."
  (cond
   ((stringp form) form)
   ((not (consp form))
    (user-error "Macro filter: %S is not a filter form" form))
   ((memq (car form) '(and or))
    (unless (cdr form)
      (user-error "Macro filter: (%s) needs at least one condition"
                  (car form)))
    (if (null (cddr form))
        (cmacs-gowl-macro-filter (cadr form))
      (concat "("
              (mapconcat #'cmacs-gowl-macro-filter (cdr form)
                         (format " %s " (car form)))
              ")")))
   ((eq (car form) 'not)
    (unless (= (length form) 2)
      (user-error "Macro filter: (not FORM) takes one form"))
    (concat "not " (let ((inner (cmacs-gowl-macro-filter (cadr form))))
                     (if (string-prefix-p "(" inner) inner
                       (concat "(" inner ")")))))
   ((memq (car form) cmacs-gowl-macro--filter-fields)
    (pcase (cdr form)
      (`(,value)
       (concat (symbol-name (car form)) "="
               (cmacs-gowl-macro--filter-value value)))
      (`(,op ,value)
       (unless (memq op cmacs-gowl-macro--filter-ops)
         (user-error "Macro filter: unknown operator %S (one of %s)" op
                     (mapconcat #'symbol-name cmacs-gowl-macro--filter-ops
                                " ")))
       (concat (symbol-name (car form)) (symbol-name op)
               (cmacs-gowl-macro--filter-value value)))
      (_ (user-error "Macro filter: %S is (FIELD VALUE) or (FIELD OP VALUE)"
                     form))))
   (t (user-error "Macro filter: unknown field or form %S (fields: %s)"
                  (car form)
                  (mapconcat #'symbol-name cmacs-gowl-macro--filter-fields
                             " ")))))

(defun cmacs-gowl-macro-trigger-string (event filter macro &rest args)
  "The trigger line for EVENT, FILTER, MACRO and ARGS.
FILTER is nil, a string or a form for `cmacs-gowl-macro-filter'."
  (unless (and (stringp event) (not (string-match-p "[][:\n]" event)))
    (user-error "Macro trigger: bad event %S" event))
  (unless (and (stringp macro) (not (string-match-p "[[:space:]]" macro)))
    (user-error "Macro trigger: bad macro name %S" macro))
  (concat event
          (and filter (concat " [" (cmacs-gowl-macro-filter filter) "]"))
          ": " macro
          (mapconcat (lambda (a) (concat " " (cmacs-gowl-macro--quote a)))
                     args "")))

(defun cmacs-gowl-macro--trigger-line (entry)
  "ENTRY of `cmacs-gowl-macro-triggers' as the line gowl reads."
  (cond ((stringp entry)
         (when (string-match-p "\n" entry)
           (user-error "Macro trigger %S: one line per trigger" entry))
         entry)
        ((and (consp entry) (>= (length entry) 3))
         (apply #'cmacs-gowl-macro-trigger-string entry))
        (t (user-error "Macro trigger %S: a string or (EVENT FILTER MACRO ARG...)"
                       entry))))

(defun cmacs-gowl-macro-list-triggers ()
  "The triggers in force, as the module understood them.
An alist with `errors' (lines refused) and `triggers': each with its
line, event or interval, filter (fully parenthesised), macro, args, and
how often it `fired' or was `skipped' by its filter."
  (cmacs-gowl-macro--json "macro-triggers"))

;;;###autoload
(defun cmacs-gowl-macro-filter-test (filter &optional event)
  "Judge FILTER against the focused window and selected monitor now.
FILTER is a string or a form for `cmacs-gowl-macro-filter'; EVENT names
the event the fields are filled in for.  Returns an alist with `match',
`filter' (as understood) and `fields' (every field's value now).
Interactively, show them."
  (interactive (list (read-string "Filter: ")))
  (let* ((text (cmacs-gowl-macro-filter filter))
         (result (cmacs-gowl-macro--json
                  (concat "macro-filter-test "
                          (if event
                              (concat "--event="
                                      (replace-regexp-in-string
                                       "[[:space:]]" "" event)
                                      " ")
                            "")
                          text))))
    (when (called-interactively-p 'interactive)
      (with-help-window "*gowl macro filter*"
        (princ (format "%s\n\n  %s\n\nFields now:\n\n"
                       (if (alist-get 'match result) "MATCHES" "does not match")
                       (alist-get 'filter result)))
        (dolist (f (alist-get 'fields result))
          (princ (format "  %-16s %s\n" (car f) (cdr f))))))
    result))

;;;; Elisp macros

(defun cmacs-gowl-macro--install (name)
  "Tell the module that NAME is an Elisp macro.
It becomes a `custom' alias whose form calls `cmacs-gowl-macro--call'
with the name, the arguments (a quoted list of strings) and the
trigger -- all string literals, quoted by the module."
  (cmacs-gowl-macro--reply
   (gowl-run-command
    (format "macro-define %s custom (cmacs-gowl-macro--call %%n '%%a %%t)"
            name))))

;;;###autoload
(defun cmacs-gowl-macro-define (name function)
  "Make FUNCTION a gowl macro called NAME.
Keybinds, `gowl-msg macro-run NAME', D-Bus, MCP, the input remapper
and other macros can then run it.  FUNCTION is called on the main
thread with the macro's arguments (strings); `cmacs-gowl-macro-trigger'
says what started it.  An error in it is caught, reported, and passed
to `cmacs-gowl-macro-fault-functions'.  NAME may not contain `/' or
whitespace.  Loads the module.  Returns NAME."
  (unless (and (stringp name)
               (string-match-p "\\`[^/[:space:]]+\\'" name))
    (user-error "Macro name %S: no `/' or whitespace" name))
  (unless (functionp function)
    (user-error "Macro %s: %S is not a function" name function))
  (puthash name function cmacs-gowl-macro--functions)
  (when (cmacs-gowl-macro--running-p)
    (cmacs-gowl-macro-ensure)
    (cmacs-gowl-macro--install name))
  name)

;;;###autoload
(defun cmacs-gowl-macro-undefine (name)
  "Forget the Elisp macro NAME."
  (interactive
   (list (completing-read "Undefine macro: "
                          (hash-table-keys cmacs-gowl-macro--functions)
                          nil t)))
  (remhash name cmacs-gowl-macro--functions)
  (when (and (cmacs-gowl-macro--running-p) cmacs-gowl-macro--enabled)
    (ignore-errors
      (cmacs-gowl-macro--reply
       (gowl-run-command (concat "macro-undefine " name)))))
  name)

(defun cmacs-gowl-macro--call (name args trigger)
  "Run the Elisp macro NAME with ARGS; what its custom form evaluates.
TRIGGER is bound to `cmacs-gowl-macro-trigger'.  An error is reported
and swallowed, as a custom keybind's is, and runs the fault hook."
  (let ((fn (gethash name cmacs-gowl-macro--functions))
        (cmacs-gowl-macro-trigger trigger))
    (if (not fn)
        (message "cmacs-gowl-macro: no Elisp macro called %s" name)
      (condition-case err
          (apply fn args)
        (error
         (cmacs-gowl-macro--fault name (error-message-string err)))))))

(defun cmacs-gowl-macro--fault (name what)
  "Macro NAME faulted with WHAT: tell the user and the hook.
Called from the module's `on-fault-custom' form for C macros, and by
`cmacs-gowl-macro--call' for Elisp ones."
  (when cmacs-gowl-macro-notify
    (message "gowl macro %s stopped: %s" name what)
    (when (fboundp 'cmacs-notify)
      (ignore-errors
        (cmacs-notify (format "Macro \"%s\" stopped" name)
                      (format "%s -- M-x cmacs-gowl-macro-clear" what)
                      'critical))))
  (condition-case err
      (run-hook-with-args 'cmacs-gowl-macro-fault-functions name what)
    (error (message "cmacs-gowl-macro-fault-functions: %s"
                    (error-message-string err)))))

;;;; The Super+space menu

;;;###autoload
(defun cmacs-gowl-macro-menu-load ()
  "Load the macro module, then reopen the gowl menu on its Macros list.
What the menu's `Load macros' row runs: the module is opt-in and loads
on first use, so until something has used it the Macros submenu has
nothing to list.  Returns t."
  (interactive)
  (cmacs-gowl-macro-ensure)
  (gowl-run-command "menu-open macros")
  t)

;;;; Recording

;;;###autoload
(defun cmacs-gowl-macro-record (&optional name)
  "Start recording a macro, or stop the one being recorded.
What you do next -- keys, clicks, drags, scrolls -- is written out as
a macro when you stop: last-recording.c, plus NAME.c when NAME is
given (interactively, with a prefix argument).  The screen wears a
frame while recording; password prompts and the lock screen are not
recorded; Super+Shift+Escape also stops it.  Returns the module's
reply."
  (interactive
   (list (and current-prefix-arg
              (not (equal (cmacs-gowl-macro-record-status) t))
              (read-string "Record as: "))))
  (let ((reply (cmacs-gowl-macro--command
                (if (and name (not (string-empty-p name)))
                    (format "macro-record start %s"
                            (cmacs-gowl-macro--quote name))
                  "macro-record"))))
    (when (called-interactively-p 'interactive)
      (message "gowl macro: %s" reply))
    reply))

(defun cmacs-gowl-macro-record-command (action &optional name for-agent)
  "Drive the recorder: ACTION is `start', `stop', `cancel' or `status'.
NAME, with `start', also writes NAME.c.  FOR-AGENT non-nil is what a
program asking passes (the MCP tool): `start' then needs gowl's
`input-recording' consent, which the record key does not.  Returns the
module's reply."
  (let ((verb (format "%s" action)))
    (unless (member verb '("start" "stop" "cancel" "status"))
      (user-error "Action must be start, stop, cancel or status, not %s"
                  verb))
    (cmacs-gowl-macro--command
     (concat "macro-record "
             (if for-agent "--require-consent " "")
             verb
             (if (and name (equal verb "start") (not (string-empty-p name)))
                 (concat " " (cmacs-gowl-macro--quote name))
               "")))))

(defun cmacs-gowl-macro-record-status ()
  "t while a macro is being recorded, else nil."
  (and (cmacs-gowl-macro--running-p)
       (let ((reply (gowl-run-command "macro-record status")))
         (and reply (string-prefix-p "OK " reply)
              (eq t (alist-get 'recording
                               (json-parse-string (substring reply 3)
                                                  :object-type 'alist
                                                  :false-object nil)))))))

;;;###autoload
(defun cmacs-gowl-macro-replay (&optional speed)
  "Play back the last recording.
SPEED is a factor: 2 is twice as fast (interactively, the prefix
argument)."
  (interactive (list (and current-prefix-arg
                          (prefix-numeric-value current-prefix-arg))))
  (if speed
      (cmacs-gowl-macro-run "last-recording" (number-to-string speed))
    (cmacs-gowl-macro-run "last-recording")))

;;;; Voice

(defvar cmacs-gowl-macro--voice nil
  "The listener: nil, or a plist (:state listening|transcribing
:handle AUDIO :chunks LIST :drain TIMER :limit TIMER).")

(defun cmacs-gowl-macro--toast (summary body)
  "Say SUMMARY and BODY on the gowl bar (when loaded) and in the echo area."
  (message "%s: %s" summary body)
  (ignore-errors
    (gowl-run-command
     (format "bar-notify %s|%s"
             (replace-regexp-in-string "[|\n]" " " summary)
             (replace-regexp-in-string "[|\n]" " " body)))))

(defun cmacs-gowl-macro--whisper-p ()
  "Non-nil when cmacs itself can listen and transcribe."
  (and (fboundp 'cmacs-audio--capture-open-1)
       (fboundp 'cmacs-whisper-transcribe-pcm-async)
       (require 'cmacs-audio nil t)
       (require 'cmacs-whisper nil t)))

(defun cmacs-gowl-macro--voice-drain ()
  "Move what the microphone has captured into the chunk list."
  (let ((handle (plist-get cmacs-gowl-macro--voice :handle)))
    (when handle
      (let ((pcm (cmacs-audio-read-pcm handle cmacs-audio-default-rate)))
        (while (> (length pcm) 0)
          (push pcm (plist-get cmacs-gowl-macro--voice :chunks))
          (setq pcm (cmacs-audio-read-pcm handle cmacs-audio-default-rate)))))))

;;;###autoload
(defun cmacs-gowl-macro-voice-text (text &optional dry-run)
  "Run the macro TEXT names, as if it had been said.
Matching is the module's: a configured phrase, then a macro's name said
as words (\"pip corner 25\" is `pip-corner 25'), then a name whose words
all appear.  With DRY-RUN, run nothing and return the module's JSON:
what was heard, the normalised form, and the macro and arguments it
would run.  Returns the module's reply."
  (interactive "sSay: ")
  (cmacs-gowl-macro--command
   (concat "macro-voice-match "
           (if dry-run "--dry-run " "")
           (string-trim (replace-regexp-in-string "[ \r\n\t]+" " " text)))))

(defun cmacs-gowl-macro-voice-status ()
  "The module's voice listener, as an alist: listening, command,
max-seconds, last-heard, last-error, phrases."
  (cmacs-gowl-macro--json "macro-voice status"))

(defun cmacs-gowl-macro--voice-heard (result)
  "Whisper's RESULT alist is in: run the macro it names."
  (setq cmacs-gowl-macro--voice nil)
  (let ((text (string-trim (or (cdr (assq :text result)) "")))
        (err (cdr (assq :error result))))
    (cond
     (err (cmacs-gowl-macro--toast "Voice" err))
     ((or (string-empty-p text)
          (member text '("[BLANK_AUDIO]" "(silence)" "[silence]")))
      (cmacs-gowl-macro--toast "Voice" "heard nothing"))
     (t
      ;; The module toasts what it heard and what it ran, or that no
      ;; macro has that name; an error here is only echoed.
      (condition-case e
          (cmacs-gowl-macro-voice-text text)
        (error (message "gowl macro voice: %s" (error-message-string e))))))))

(defun cmacs-gowl-macro--voice-stop ()
  "Stop listening and hand the recording to whisper."
  (let ((v cmacs-gowl-macro--voice))
    (dolist (k '(:drain :limit))
      (when (timerp (plist-get v k)) (cancel-timer (plist-get v k))))
    (cmacs-gowl-macro--voice-drain)
    (let ((pcm (apply #'concat (reverse (plist-get cmacs-gowl-macro--voice
                                                   :chunks)))))
      (ignore-errors (cmacs-audio-close (plist-get v :handle)))
      (if (< (length pcm) (/ cmacs-audio-default-rate 2))
          (progn (setq cmacs-gowl-macro--voice nil)
                 (cmacs-gowl-macro--toast "Voice" "heard nothing"))
        (setq cmacs-gowl-macro--voice (list :state 'transcribing))
        (cmacs-gowl-macro--toast "Voice" "transcribing...")
        (cmacs-whisper-transcribe-pcm-async
         (cmacs-whisper-model-path) pcm
         #'cmacs-gowl-macro--voice-heard cmacs-whisper-language)))))

;;;###autoload
(defun cmacs-gowl-macro-voice ()
  "Say a macro's name and run it: press once, speak, press again.
Listening stops by itself after `cmacs-gowl-macro-voice-max-seconds'.
cmacs records and transcribes with its own whisper (see
`cmacs-gowl-macro-voice-backend'); the module matches what was said to
a macro with `cmacs-gowl-macro-voice-text'.  Bound to Super+Alt+m."
  (interactive)
  (cmacs-gowl-macro-ensure)
  (cond
   ((or (eq cmacs-gowl-macro-voice-backend 'command)
        (not (cmacs-gowl-macro--whisper-p)))
    (cmacs-gowl-macro--command "macro-voice"))
   ((eq (plist-get cmacs-gowl-macro--voice :state) 'transcribing)
    (cmacs-gowl-macro--toast "Voice" "still transcribing the last one"))
   ((eq (plist-get cmacs-gowl-macro--voice :state) 'listening)
    (cmacs-gowl-macro--voice-stop))
   ((not (file-exists-p (cmacs-whisper-model-path)))
    (cmacs-gowl-macro--toast
     "Voice" (format "no whisper model at %s -- M-x cmacs-whisper-download-model"
                     (cmacs-whisper-model-path))))
   (t
    (let ((handle (cmacs-audio--capture-open-1
                   :source cmacs-audio-capture-source
                   :rate cmacs-audio-default-rate
                   :channels 1
                   :device cmacs-audio-default-device)))
      (cmacs-audio-start handle)
      (setq cmacs-gowl-macro--voice
            (list :state 'listening :handle handle :chunks nil
                  :drain (run-with-timer 0.5 0.5
                                         #'cmacs-gowl-macro--voice-drain)
                  :limit (run-with-timer cmacs-gowl-macro-voice-max-seconds
                                         nil #'cmacs-gowl-macro--voice-stop)))
      (cmacs-gowl-macro--toast "Listening"
                               "say a macro's name; Super+Alt+m when done")))))

;;;; Keys

;;;###autoload
(defun cmacs-gowl-macro-bind (key name &rest args)
  "Bind gowl KEY (\"Super+s\") to run macro NAME with ARGS.
A compositor keybind, so it works whichever window has focus.  Loads
the module."
  (cmacs-gowl-macro-ensure)
  (gowl-add-keybind key 'ipc-command
                    (mapconcat #'identity
                               (append (list "macro-run"
                                             (cmacs-gowl-macro--quote name))
                                       (mapcar #'cmacs-gowl-macro--quote args))
                               " ")
                    (format "Macro: %s" name)))

;;;; Writing macro files

(defun cmacs-gowl-macro--new-dir ()
  "Where `cmacs-gowl-macro-new' puts a new file."
  (expand-file-name
   (or (car-safe cmacs-gowl-macro-directory)
       (and (stringp cmacs-gowl-macro-directory) cmacs-gowl-macro-directory)
       (expand-file-name "gowl/macros"
                         (or (getenv "XDG_CONFIG_HOME") "~/.config")))))

(defconst cmacs-gowl-macro--template
  "/*
 * %s.c - %s
 *
 * Run it:  gowl-msg macro-run %s
 *          (cmacs-gowl-macro-run \"%s\")
 *
 * Steps (key, text, wait, action, ...) are queued and played after this
 * returns; helpers (find_client, list_clients, ...) act now.  Add
 *   #define GOWL_MACRO_THREADED 1
 * to run on a worker thread, where gowl_macro_sleep() is allowed.
 */

#include <gowl/gowl.h>

G_MODULE_EXPORT const gchar *
gowl_macro_info(void)
{
	return \"%s\";
}

G_MODULE_EXPORT gboolean
gowl_macro_run(GowlMacroContext *ctx)
{
	/* e.g. gowl_macro_action(ctx, GOWL_ACTION_SET_LAYOUT, \"tile\"); */
	gowl_macro_set_result(ctx, \"done\");
	return TRUE;
}
"
  "Skeleton for `cmacs-gowl-macro-new': name x4, description x2.")

;;;###autoload
(defun cmacs-gowl-macro-new (name description)
  "Create macro NAME in your macro directory and visit it.
DESCRIPTION is the one line `macro-list' shows."
  (interactive "sNew macro name: \nsWhat it does: ")
  (when (string-match-p "[/[:space:]]" name)
    (user-error "Macro name %S: no `/' or whitespace" name))
  (let* ((dir (cmacs-gowl-macro--new-dir))
         (file (expand-file-name (concat name ".c") dir)))
    (when (file-exists-p file)
      (user-error "%s already exists" file))
    (make-directory dir t)
    (with-temp-file file
      (insert (format cmacs-gowl-macro--template name description name name
                      description)))
    (find-file file)))

;;;###autoload
(defun cmacs-gowl-macro-visit (name)
  "Visit the source of macro NAME, wherever the search path found it."
  (interactive (list (cmacs-gowl-macro--read-name "Visit macro: ")))
  (let ((path (alist-get 'path (cmacs-gowl-macro-info name))))
    (unless (and path (file-exists-p path))
      (user-error "Macro %s has no source file" name))
    (find-file path)))

;;;; A list of macros

(defvar-keymap cmacs-gowl-macro-list-mode-map
  :doc "Keymap for `cmacs-gowl-macro-list-mode'."
  "RET" #'cmacs-gowl-macro-list-run
  "v"   #'cmacs-gowl-macro-list-visit
  "c"   #'cmacs-gowl-macro-list-clear
  "s"   #'cmacs-gowl-macro-stop
  "n"   #'cmacs-gowl-macro-new)

(define-derived-mode cmacs-gowl-macro-list-mode tabulated-list-mode
  "gowl-macros"
  "Every gowl macro runnable by name.

\\{cmacs-gowl-macro-list-mode-map}"
  (setq tabulated-list-format [("Name" 22 t) ("Kind" 11 t) ("Held" 5 t)
                               ("Where" 0 t)])
  (setq tabulated-list-sort-key '("Name" . nil))
  (add-hook 'tabulated-list-revert-hook
            #'cmacs-gowl-macro--list-refresh nil t)
  (tabulated-list-init-header))

(defun cmacs-gowl-macro--list-refresh ()
  "Fill the macro list from the module."
  (setq tabulated-list-entries
        (mapcar (lambda (m)
                  (let ((name (alist-get 'name m)))
                    (list name
                          (vector name
                                  (or (alist-get 'kind m) "")
                                  (if (alist-get 'held-back m) "yes" "")
                                  (abbreviate-file-name
                                   (or (alist-get 'path m) ""))))))
                (cmacs-gowl-macro-list))))

(defun cmacs-gowl-macro-list-run ()
  "Run the macro at point, asking for arguments."
  (interactive)
  (let ((name (tabulated-list-get-id)))
    (unless name (user-error "No macro here"))
    (message "Macro: %s"
             (apply #'cmacs-gowl-macro-run name
                    (split-string-shell-command
                     (read-string (format "Arguments for %s: " name)))))
    (revert-buffer)))

(defun cmacs-gowl-macro-list-visit ()
  "Visit the source of the macro at point."
  (interactive)
  (cmacs-gowl-macro-visit (or (tabulated-list-get-id)
                              (user-error "No macro here"))))

(defun cmacs-gowl-macro-list-clear ()
  "Let the macro at point run again."
  (interactive)
  (cmacs-gowl-macro-clear (or (tabulated-list-get-id)
                              (user-error "No macro here")))
  (revert-buffer))

;;;###autoload
(defun cmacs-gowl-macro-list-macros ()
  "Show every gowl macro runnable by name."
  (interactive)
  (with-current-buffer (get-buffer-create "*gowl macros*")
    (cmacs-gowl-macro-list-mode)
    (cmacs-gowl-macro--list-refresh)
    (tabulated-list-print)
    (pop-to-buffer (current-buffer))))

;;;; Startup

(defun cmacs-gowl-macro--on-start ()
  "Enable the module at compositor start if anything is configured.
Called by `cmacs-gowl-mode'.  Loads nothing when nothing is."
  (setq cmacs-gowl-macro--enabled nil)
  (when (or cmacs-gowl-macro-definitions
            cmacs-gowl-macro-triggers
            (> (hash-table-count cmacs-gowl-macro--functions) 0))
    (condition-case err
        (cmacs-gowl-macro-ensure)
      (error (message "cmacs-gowl-macro: %s" (error-message-string err))))))

(provide 'cmacs-gowl-macro)

;;; cmacs-gowl-macro.el ends here
