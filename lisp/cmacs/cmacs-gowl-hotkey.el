;;; cmacs-gowl-hotkey.el --- AutoHotkey for gowl, from Elisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `hotkey' module is AutoHotkey done in the compositor: hotkeys
;; on keys, mouse buttons and wheel notches -- in AutoHotkey's notation
;; (\"#!t\", \"~LButton\", \"CapsLock & j\", \"^a UP\") or gowl's
;; (\"Super+Alt+t\") -- that run lists of actions, plus remaps, contexts
;; (#HotIf), modes, double taps, long presses, hotstrings, timers and
;; event hooks.  It decides every key before any keybind and before a
;; fullscreen game's shortcuts-inhibit.  This file is its Elisp surface
;; under `cmacs --gowl', and what makes an Elisp function a hotkey:
;;
;;   (setq cmacs-gowl-hotkey-enable t)
;;   (cmacs-gowl-hotkey-define "#!c" #'org-capture)
;;   (cmacs-gowl-hotkey-define "CapsLock & e"
;;     (lambda () (find-file "~/Documents/notes/00_inbox/00_index.org")))
;;   (cmacs-gowl-hotkey-define "F9" nil
;;     :do '((:shell "grim ~/shot.png") (:notify "saved")))
;;
;; NOTHING HAPPENS BY DEFAULT.  The module is opt-in: it is loaded only
;; when `cmacs-gowl-hotkey-enable' is non-nil, something is configured
;; (`cmacs-gowl-hotkey-definitions', `-remaps', `-hotstrings',
;; `-section', `-scripts'), or a `cmacs-gowl-hotkey-' function is used.
;;
;; How an Elisp hotkey runs.  The compositor decides the key on its own
;; thread, where Lisp must never run; the hotkey's action is a `custom'
;; action whose form, (cmacs-gowl-hotkey--call ID TRIGGER), cmacs's
;; custom-action handler queues to Emacs's main loop -- the same path a
;; custom keybind takes.  So the key is swallowed at once and the
;; function runs a moment later on the main thread, with
;; `cmacs-gowl-hotkey-current' and `cmacs-gowl-hotkey-trigger' bound.
;;
;; Contexts written in Elisp (`cmacs-gowl-hotkey-define-context') are
;; evaluated here when the focus or a title changes, and only their
;; answer -- a boolean -- is pushed to the module: a key is never kept
;; waiting for Lisp.
;;
;; Everything goes through `gowl-run-command' and the module's
;; `hotkey-' words -- the same ones the IPC socket, MCP and D-Bus reach
;; -- so no new C primitive is involved.  See "Hotkeys (AutoHotkey)" in
;; the gowl chapter of the cmacs manual, deps/gowl/docs/hotkey.org for
;; the module, and etc/cmacs/examples/gowl-hotkey-examples.el for a
;; cookbook.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'cmacs-gowl-macro)

(declare-function gowl-run-command "cmacs-gowl")
(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-enable-module "cmacs-gowl")
(declare-function gowl-disable-module "cmacs-gowl")
(declare-function gowl-configure-module "cmacs-gowl")
(declare-function gowl-focused-client "cmacs-gowl")
(declare-function gowl-client-info "cmacs-gowl")
(defvar cmacs-gowl-module-event-functions)
(defvar cmacs-gowl-focus-changed-functions)
(defvar cmacs-gowl-client-title-changed-functions)

(defgroup cmacs-gowl-hotkey nil
  "AutoHotkey-style hotkeys in gowl."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-hotkey-")

;;;; Options

(defcustom cmacs-gowl-hotkey-enable nil
  "Non-nil to load gowl's `hotkey' module whenever the compositor starts.
nil, the default, loads it only when something is configured or a
`cmacs-gowl-hotkey-' function is first used."
  :type 'boolean
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-suspend-key "Super+Shift+Pause"
  "The key that suspends and resumes every hotkey but itself; nil for none.
AutoHotkey's Suspend.  A toast says which way."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-send-mode 'input
  "How sent keys are typed: `input' all at once, `event' paced.
`event' with `cmacs-gowl-hotkey-key-delay' is for applications and
games that drop fast keys."
  :type '(choice (const input) (const event))
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-key-delay 0
  "Milliseconds between sent keys; non-zero implies the `event' mode."
  :type 'natnum
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-accept-synthetic nil
  "Non-nil to let another program's injected keys fire hotkeys.
For a software KVM (deskflow) driving this machine; hotkeys written
with `$' still refuse such input."
  :type 'boolean
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-c-timeout 2000
  "Milliseconds a C action, function or context may run before it is stopped."
  :type 'natnum
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-toast t
  "Non-nil for toasts on suspend, mode changes and `notify' actions."
  :type 'boolean
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-log nil
  "Non-nil to log every decision the module makes to the journal."
  :type 'boolean
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-scripts nil
  "Crispy hotkey scripts (C files) the module builds, loads and watches.
The .ahk files of gowl: each registers hotkeys, functions and contexts
from `gowl_hotkey_script_init()' and is rebuilt when saved.  See
deps/gowl/data/example-hotkey-script.c."
  :type '(repeat file)
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-definitions nil
  "Hotkeys to install whenever the compositor starts.
Each element is (KEY FUNCTION . PLIST), the arguments of
`cmacs-gowl-hotkey-define':

  (\"#!c\" org-capture)
  (\"F9\" nil :do ((:shell \"grim ~/shot.png\")))"
  :type '(repeat (cons (string :tag "Key")
                       (cons (choice (const :tag "No function" nil) function)
                             (plist :tag "Options"))))
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-remaps nil
  "Remaps, AutoHotkey's a::b, as an alist of (FROM . TO) key names.

  ((\"CapsLock\" . \"Control_L\") (\"XButton2\" . \"MButton\"))"
  :type '(alist :key-type string :value-type string)
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-hotstrings nil
  "Hotstrings, handed to the gabbrev module (which types them).
Each element is AutoHotkey's \":OPTIONS:ABBREVIATION::REPLACEMENT\", or
\(ABBREVIATION . REPLACEMENT):

  (\"::btw::by the way\" (\"brb\" . \"be right back\"))"
  :type '(repeat (choice string (cons string string)))
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-section nil
  "A whole `hotkey:' section -- anything the module's YAML takes.
A string of YAML, or Lisp data turned into it: plists and alists become
mappings, lists and vectors sequences (see `cmacs-gowl-hotkey-yaml').

  (:hotkeys [(:key \"#r\" :do (:mode \"resize\"))]
   :modes (:resize
           (:timeout \"2s\"
            :hotkeys [(:key \"h\"
                       :do (:window \"move-by\" :arg \"-40 0\"))])))"
  :type '(choice (const :tag "None" nil) string sexp)
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-fired-functions nil
  "Abnormal hook run with the id of every hotkey that fires.
Whatever the hotkey runs -- Elisp or not -- and however it was fired:
a key, `cmacs-gowl-hotkey-fire', the IPC socket, D-Bus."
  :type 'hook
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-fault-functions nil
  "Abnormal hook run with ID and WHAT when a hotkey's action fails.
ID is the hotkey's id, or nil for a fault the module reported (a C
action crashing, a script failing to build); WHAT says what happened."
  :type 'hook
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-changed-functions nil
  "Abnormal hook run with WHAT and VALUE when the module's state changes.
WHAT is `suspended' (VALUE t or nil) or `mode' (VALUE the mode's name,
\"default\" for none)."
  :type 'hook
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-input-functions nil
  "Abnormal hook run with NAME, REASON and TEXT when an input hook ends.
REASON is \"max\", \"match\", \"endkey:KEY\", \"timeout\", \"mouse\" or
\"stopped\"; TEXT is what was typed.  See `cmacs-gowl-hotkey-input'."
  :type 'hook
  :group 'cmacs-gowl-hotkey)

(defcustom cmacs-gowl-hotkey-lighter " HK"
  "Mode-line text shown while hotkeys are suspended or a mode is entered.
Followed by \":off\" or \":MODE\"; nil for nothing."
  :type '(choice (const :tag "Nothing" nil) string)
  :group 'cmacs-gowl-hotkey)

;;;; State

(defconst cmacs-gowl-hotkey--module "hotkey"
  "The gowl module this file drives.")

(defconst cmacs-gowl-hotkey--fields
  '(app-id class title exec pid id xwayland floating fullscreen monitor
           layout tags tag time hour weekday mode)
  "Fields a hotkey's :when, :over, :exists and :absent may test.
Mirrors the module's window fields (gowl-module-hotkey.c).")

(defconst cmacs-gowl-hotkey--entry-keys
  '(:id :do :context :when :over :exists :absent :mode :double :hold
        :priority :level :suspend-exempt :max-running :enabled :description)
  "The keys `cmacs-gowl-hotkey-define' takes.")

(defvar cmacs-gowl-hotkey-current nil
  "The id of the hotkey whose Elisp function is running, else nil.")

(defvar cmacs-gowl-hotkey-trigger nil
  "What fired the running hotkey: \"hotkey\", \"ipc\", \"timer\", ...")

(defvar cmacs-gowl-hotkey--functions (make-hash-table :test #'equal)
  "Hotkey id -> the Elisp function it runs.")

(defvar cmacs-gowl-hotkey--defined nil
  "Hotkeys defined this session as (ID KEY FUNCTION . PLIST), newest first.
Replayed when the compositor (re)starts.")

(defvar cmacs-gowl-hotkey--named-functions (make-hash-table :test #'equal)
  "Function name -> the Elisp function `call:' actions reach.")

(defvar cmacs-gowl-hotkey--contexts (make-hash-table :test #'equal)
  "Context name -> its Elisp predicate.")

(defvar cmacs-gowl-hotkey--context-values (make-hash-table :test #'equal)
  "Context name -> the answer last pushed to the module (t or nil).")

(defvar cmacs-gowl-hotkey--sections nil
  "Sections added this session, as (ID . YAML), newest first.")

(defvar cmacs-gowl-hotkey--enabled nil
  "Non-nil once the module has been loaded in this compositor.")

(defvar cmacs-gowl-hotkey--suspended nil
  "Non-nil while hotkeys are suspended, as the module last said.")

(defvar cmacs-gowl-hotkey--mode nil
  "The key mode the module last announced, or nil for the default.")

(defvar cmacs-gowl-hotkey--context-timer nil
  "The pending context refresh, coalescing a burst of focus changes.")

;;;; Talking to the module

(defmacro cmacs-gowl-hotkey--try (what &rest body)
  "Run BODY; report an error as being about WHAT instead of signalling."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (message "cmacs-gowl-hotkey: %s: %s" ,what
                     (error-message-string err)))))


(defun cmacs-gowl-hotkey--running-p ()
  "Non-nil when the compositor is running."
  (and (fboundp 'gowl-running-p) (gowl-running-p)))

(defun cmacs-gowl-hotkey--command (line)
  "Run the module command LINE and return the text after \"OK \".
An \"ERROR ...\" reply becomes a `user-error' carrying the module's own
explanation; no reply at all means the module is not loaded."
  (unless (cmacs-gowl-hotkey--running-p)
    (user-error "Gowl compositor is not running"))
  (let ((reply (gowl-run-command line)))
    (cond ((null reply)
           (user-error "The gowl hotkey module is not loaded; call `cmacs-gowl-hotkey-start'"))
          ((string-prefix-p "ERROR" reply)
           (user-error "Hotkey: %s" (string-trim (substring reply 5))))
          ((string-prefix-p "OK " reply) (substring reply 3))
          ((equal reply "OK") "")
          (t reply))))

(defun cmacs-gowl-hotkey--json (line)
  "Run module command LINE and parse its JSON reply into alists."
  (json-parse-string (cmacs-gowl-hotkey--command line)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun cmacs-gowl-hotkey--bool (v)
  "V as the module's \"true\" / \"false\"."
  (if v "true" "false"))

(defun cmacs-gowl-hotkey--settings ()
  "The module settings, as the string alist `gowl-configure-module' takes.
D-Bus stays off: under cmacs the editor's own interface serves it."
  (append
   (list (cons "suspend-key" (or cmacs-gowl-hotkey-suspend-key "none"))
         (cons "send-mode" (symbol-name cmacs-gowl-hotkey-send-mode))
         (cons "key-delay" (number-to-string cmacs-gowl-hotkey-key-delay))
         (cons "accept-synthetic" (cmacs-gowl-hotkey--bool
                                   cmacs-gowl-hotkey-accept-synthetic))
         (cons "c-timeout" (number-to-string cmacs-gowl-hotkey-c-timeout))
         (cons "toast" (cmacs-gowl-hotkey--bool cmacs-gowl-hotkey-toast))
         (cons "log" (cmacs-gowl-hotkey--bool cmacs-gowl-hotkey-log))
         (cons "dbus" "false"))
   (and cmacs-gowl-hotkey-scripts
        (list (cons "scripts"
                    (mapconcat #'expand-file-name
                               cmacs-gowl-hotkey-scripts ","))))))

;;;; Lisp data as the module's YAML

(defun cmacs-gowl-hotkey--name (x)
  "X, a keyword, symbol, string or number, as a string."
  (cond ((keywordp x) (substring (symbol-name x) 1))
        ((symbolp x) (symbol-name x))
        ((stringp x) x)
        (t (format "%s" x))))

(defun cmacs-gowl-hotkey--plist-p (x)
  "Non-nil when X is a non-empty plist with keyword keys."
  (and (consp x) (keywordp (car x)) (proper-list-p x)
       (cl-evenp (length x))))

(defun cmacs-gowl-hotkey--alist-p (x)
  "Non-nil when X is an alist of (SYMBOL-OR-STRING . VALUE)."
  (and (consp x) (proper-list-p x)
       (cl-every (lambda (e)
                   (and (consp e)
                        (or (stringp (car e))
                            (and (symbolp (car e)) (car e)
                                 (not (keywordp (car e)))))))
                 x)))

(defun cmacs-gowl-hotkey--data (x)
  "X as the value `json-serialize' takes.
Plists and alists become objects, other lists and vectors arrays,
symbols and keywords strings, t true and nil false."
  (cond ((eq x t) t)
        ((null x) :false)
        ((eq x :false) :false)
        ((or (stringp x) (numberp x)) x)
        ((symbolp x) (cmacs-gowl-hotkey--name x))
        ((vectorp x) (vconcat (mapcar #'cmacs-gowl-hotkey--data x)))
        ((cmacs-gowl-hotkey--plist-p x)
         (cl-loop for (k v) on x by #'cddr
                  collect (cons (intern (cmacs-gowl-hotkey--name k))
                                (cmacs-gowl-hotkey--data v))))
        ((cmacs-gowl-hotkey--alist-p x)
         (mapcar (lambda (e)
                   (cons (intern (cmacs-gowl-hotkey--name (car e)))
                         (cmacs-gowl-hotkey--data (cdr e))))
                 x))
        ((proper-list-p x) (vconcat (mapcar #'cmacs-gowl-hotkey--data x)))
        (t (user-error "Hotkey: cannot express %S as YAML" x))))

(defun cmacs-gowl-hotkey-yaml (data)
  "DATA as YAML the module reads: a string as it is, else JSON.
JSON is YAML flow syntax, so Lisp data -- plists, alists, lists,
vectors -- is turned into it by `cmacs-gowl-hotkey--data'."
  (if (stringp data) data
    (json-serialize (cmacs-gowl-hotkey--data data))))

(defun cmacs-gowl-hotkey--actions (do)
  "DO -- one action or a list of them -- as a list of action values.
An action is a plist (:shell \"x\"), an alist ((shell . \"x\")), or a
string, which the module reads as a gowl command line."
  (cond ((null do) nil)
        ((or (stringp do) (cmacs-gowl-hotkey--plist-p do)
             (cmacs-gowl-hotkey--alist-p do))
         (list (cmacs-gowl-hotkey--data do)))
        ((vectorp do) (mapcar #'cmacs-gowl-hotkey--data do))
        ((proper-list-p do) (mapcar #'cmacs-gowl-hotkey--data do))
        (t (user-error "Hotkey: :do is an action or a list of them, not %S"
                       do))))

(defun cmacs-gowl-hotkey--filter (form what)
  "FORM -- filter text or a Lisp filter form -- as filter text.
WHAT names the caller in errors."
  (cmacs-gowl-filter-form form cmacs-gowl-hotkey--fields what))

(defun cmacs-gowl-hotkey--word (x what)
  "X as one word -- no whitespace -- for WHAT in errors."
  (let ((s (cmacs-gowl-hotkey--name x)))
    (when (or (string-empty-p s) (string-match-p "[[:space:]]" s))
      (user-error "Hotkey: %s %S must be one word" what s))
    s))

(defun cmacs-gowl-hotkey--call-form ()
  "The custom form an Elisp hotkey runs (%i and %t filled in by the module)."
  "(cmacs-gowl-hotkey--call %i %t)")

(defun cmacs-gowl-hotkey-entry (key function &rest plist)
  "The hotkey entry KEY with FUNCTION and PLIST, as `json-serialize' data.
PLIST is what `cmacs-gowl-hotkey-define' takes."
  (let* ((id (if (plist-get plist :id)
                 (cmacs-gowl-hotkey--word (plist-get plist :id) "id")
               key))
         (actions (append (cmacs-gowl-hotkey--actions (plist-get plist :do))
                          (and function
                               (list `((custom . ,(cmacs-gowl-hotkey--call-form)))))))
         (entry `((id . ,id) (key . ,key))))
    (unless (and (stringp key) (not (string-empty-p key)))
      (user-error "Hotkey: the key must be a string, not %S" key))
    (cl-loop for (k _) on plist by #'cddr
             unless (memq k cmacs-gowl-hotkey--entry-keys)
             do (user-error "Hotkey %s: unknown key %s" key k))
    (unless actions
      (user-error "Hotkey %s: needs a function or :do" key))
    (dolist (k '(:when :over :exists :absent))
      (when (plist-get plist k)
        (setq entry (append entry
                            (list (cons (intern (cmacs-gowl-hotkey--name k))
                                        (cmacs-gowl-hotkey--filter
                                         (plist-get plist k)
                                         (format "Hotkey %s" key))))))))
    (dolist (k '(:context :mode :description))
      (when (plist-get plist k)
        (setq entry (append entry
                            (list (cons (intern (cmacs-gowl-hotkey--name k))
                                        (cmacs-gowl-hotkey--name
                                         (plist-get plist k))))))))
    (dolist (k '(:double :hold :priority :level :max-running))
      (when (plist-member plist k)
        (let ((v (plist-get plist k)))
          (unless (or (eq v t) (null v) (integerp v) (stringp v))
            (user-error "Hotkey %s: %s is t, a number or a duration" key k))
          (when v
            (setq entry (append entry
                                (list (cons (intern (cmacs-gowl-hotkey--name k))
                                            v))))))))
    (dolist (k '(:suspend-exempt :enabled))
      (when (plist-member plist k)
        (setq entry (append entry
                            (list (cons (intern (cmacs-gowl-hotkey--name k))
                                        (if (plist-get plist k) t :false)))))))
    (append entry `((do . ,(vconcat actions))))))

(defun cmacs-gowl-hotkey-entry-json (key function &rest plist)
  "The `hotkey-add' text for KEY, FUNCTION and PLIST: one JSON section."
  (json-serialize
   `((hotkeys . [,(apply #'cmacs-gowl-hotkey-entry key function plist)]))))

;;;; Loading the module

;;;###autoload
(defun cmacs-gowl-hotkey-start ()
  "Load gowl's `hotkey' module, push its settings, install what is defined.
Idempotent: the configured remaps, hotstrings and section, every hotkey,
function and context defined this session."
  (interactive)
  (unless (cmacs-gowl-hotkey--running-p)
    (user-error "Gowl compositor is not running"))
  (unless (gowl-run-command "hotkey-status")
    (gowl-enable-module cmacs-gowl-hotkey--module))
  (condition-case err
      (gowl-configure-module cmacs-gowl-hotkey--module
                             (cmacs-gowl-hotkey--settings))
    (error (message "cmacs-gowl-hotkey: settings failed: %s"
                    (error-message-string err))))
  (setq cmacs-gowl-hotkey--enabled t)
  (cmacs-gowl-hotkey--listen t)
  (cmacs-gowl-hotkey--install-config)
  (dolist (s (reverse cmacs-gowl-hotkey--sections))
    (cmacs-gowl-hotkey--try (format "section %s" (car s))
      (cmacs-gowl-hotkey--send-section (car s) (cdr s))))
  (maphash (lambda (name _)
             (cmacs-gowl-hotkey--try (format "function %s" name)
               (cmacs-gowl-hotkey--send-function name)))
           cmacs-gowl-hotkey--named-functions)
  (dolist (d (reverse cmacs-gowl-hotkey--defined))
    (cmacs-gowl-hotkey--try (format "hotkey %s" (car d))
      (cmacs-gowl-hotkey--send-hotkey d)))
  (clrhash cmacs-gowl-hotkey--context-values)
  (cmacs-gowl-hotkey-refresh-contexts)
  (when (called-interactively-p 'interactive)
    (message "Hotkey: loaded, %d Elisp hotkey(s); %s suspends"
             (length cmacs-gowl-hotkey--defined)
             (or cmacs-gowl-hotkey-suspend-key "nothing"))))

;;;###autoload
(defun cmacs-gowl-hotkey-stop ()
  "Unload the module: no hotkey fires, every remapped key is released.
What is defined is kept; `cmacs-gowl-hotkey-start' brings it back."
  (interactive)
  (when (cmacs-gowl-hotkey--running-p)
    (gowl-disable-module cmacs-gowl-hotkey--module))
  (setq cmacs-gowl-hotkey--enabled nil)
  (cmacs-gowl-hotkey--listen nil)
  (cmacs-gowl-hotkey--set-state 'suspended nil)
  (cmacs-gowl-hotkey--set-state 'mode nil))

(defun cmacs-gowl-hotkey-ensure ()
  "Load the module if this compositor has not got it yet."
  (unless cmacs-gowl-hotkey--enabled
    (cmacs-gowl-hotkey-start)))

(defun cmacs-gowl-hotkey--config-section ()
  "The remaps and hotstrings options as one section's data, or nil."
  (let (out)
    (when cmacs-gowl-hotkey-remaps
      (push (cons 'remaps
                  (mapcar (lambda (r)
                            (cons (intern (cmacs-gowl-hotkey--name (car r)))
                                  (cmacs-gowl-hotkey--name (cdr r))))
                          cmacs-gowl-hotkey-remaps))
            out))
    (when cmacs-gowl-hotkey-hotstrings
      (push (cons 'hotstrings
                  (vconcat
                   (mapcar (lambda (h)
                             (if (stringp h) h
                               `((trigger . ,(car h)) (replace . ,(cdr h)))))
                           cmacs-gowl-hotkey-hotstrings)))
            out))
    (nreverse out)))

(defun cmacs-gowl-hotkey--install-config ()
  "Send the options' remaps, hotstrings and section to the module."
  (let ((rh (cmacs-gowl-hotkey--config-section)))
    (when rh
      (cmacs-gowl-hotkey--try "remaps and hotstrings"
        (cmacs-gowl-hotkey--send-section "cmacs-options" rh))))
  (when cmacs-gowl-hotkey-section
    (cmacs-gowl-hotkey--try "cmacs-gowl-hotkey-section"
      (cmacs-gowl-hotkey--send-section "cmacs-section"
                                       cmacs-gowl-hotkey-section))))

;;;; Hotkeys

(defun cmacs-gowl-hotkey--send-hotkey (definition)
  "Send DEFINITION, (ID KEY FUNCTION . PLIST), to the module."
  (cmacs-gowl-hotkey--command
   (concat "hotkey-add "
           (apply #'cmacs-gowl-hotkey-entry-json (nth 1 definition)
                  (nth 2 definition) (nthcdr 3 definition)))))

;;;###autoload
(defun cmacs-gowl-hotkey-define (key function &rest plist)
  "Make KEY a hotkey running FUNCTION (or the actions in :do); return its id.
KEY is AutoHotkey's notation (\"#!c\", \"^+Enter\", \"CapsLock & j\",
\"~LButton\", \"^WheelUp\", \"a UP\") or gowl's (\"Super+Alt+c\").
FUNCTION is called with no arguments on the main thread, a moment
after the key, with `cmacs-gowl-hotkey-current' (the id) and
`cmacs-gowl-hotkey-trigger' bound; an error in it is caught and
passed to `cmacs-gowl-hotkey-fault-functions'.  It may be nil when :do
says what to do.  PLIST keys:

  :id NAME          the hotkey's id (default KEY); defining the same
                    id again replaces it
  :do ACTIONS       gowl actions run before FUNCTION: a plist such as
                    (:shell \"grim ~/s.png\"), a list of them, or a gowl
                    command line -- every action in hotkey.org
  :context NAME     only where context NAME holds -- one defined by
                    `cmacs-gowl-hotkey-define-context', in YAML, or in C
  :when FORM        only when the focused window matches FORM: filter
                    text or a form like (app-id \"librewolf\")
  :over FORM        only when the window under the pointer matches
  :exists FORM      only while some window matches
  :absent FORM      only while no window matches
  :mode NAME        only in key mode NAME (\"*\" for every mode)
  :double MS        fire on a double tap (t for 300 ms)
  :hold MS          fire on a long press (t for 500 ms)
  :priority N       higher wins among hotkeys matching one press
  :level N          the input level (AutoHotkey's #InputLevel)
  :suspend-exempt B keep firing while hotkeys are suspended
  :max-running N    runs of it at once (default 1, 0 = no limit)
  :enabled B        nil defines it switched off
  :description TEXT shown by `cmacs-gowl-hotkey-show'

When the compositor is not running yet, the hotkey is kept and
installed when it starts."
  (let* ((id (if (plist-get plist :id)
                 (cmacs-gowl-hotkey--word (plist-get plist :id) "id")
               key))
         (definition (cl-list* id key function plist)))
    (when (and function (not (functionp function)))
      (user-error "Hotkey %s: %S is not a function" key function))
    ;; Check it now, so a mistake is reported where it was made
    (apply #'cmacs-gowl-hotkey-entry key function plist)
    (if function
        (puthash id function cmacs-gowl-hotkey--functions)
      (remhash id cmacs-gowl-hotkey--functions))
    (setq cmacs-gowl-hotkey--defined
          (cons definition
                (cl-remove id cmacs-gowl-hotkey--defined
                           :key #'car :test #'equal)))
    (when (cmacs-gowl-hotkey--running-p)
      (if cmacs-gowl-hotkey--enabled
          (cmacs-gowl-hotkey--send-hotkey definition)
        (cmacs-gowl-hotkey-start)))
    id))

;;;###autoload
(defun cmacs-gowl-hotkey-undefine (id)
  "Forget the hotkey ID defined from Elisp (or added at run time)."
  (interactive
   (list (completing-read "Undefine hotkey: "
                          (mapcar #'car cmacs-gowl-hotkey--defined) nil t)))
  (remhash id cmacs-gowl-hotkey--functions)
  (setq cmacs-gowl-hotkey--defined
        (cl-remove id cmacs-gowl-hotkey--defined :key #'car :test #'equal))
  (when (and (cmacs-gowl-hotkey--running-p) cmacs-gowl-hotkey--enabled)
    (ignore-errors (cmacs-gowl-hotkey--command (concat "hotkey-remove " id))))
  id)

(defun cmacs-gowl-hotkey--call (id trigger)
  "Run the Elisp function of hotkey ID; what its custom form evaluates.
TRIGGER is bound to `cmacs-gowl-hotkey-trigger'.  An error is reported
and swallowed, as a custom keybind's is, and runs the fault hook."
  (let ((fn (gethash id cmacs-gowl-hotkey--functions))
        (cmacs-gowl-hotkey-current id)
        (cmacs-gowl-hotkey-trigger trigger))
    (if (not fn)
        (message "cmacs-gowl-hotkey: no Elisp function for hotkey %s" id)
      (condition-case err
          (if (commandp fn) (call-interactively fn) (funcall fn))
        (error (cmacs-gowl-hotkey--fault id (error-message-string err)))))))

(defun cmacs-gowl-hotkey--fault (id what)
  "Hotkey ID (nil: the module) failed with WHAT: tell the user and the hook."
  (message "gowl hotkey%s: %s" (if id (concat " " id) "") what)
  (condition-case err
      (run-hook-with-args 'cmacs-gowl-hotkey-fault-functions id what)
    (error (message "cmacs-gowl-hotkey-fault-functions: %s"
                    (error-message-string err)))))

;;;; Functions (call: actions)

(defun cmacs-gowl-hotkey--send-function (name)
  "Tell the module that NAME is an Elisp function `call:' can reach."
  (cmacs-gowl-hotkey--command
   (format "hotkey-func-define %s (cmacs-gowl-hotkey--call-function %s %%a %%t)"
           name (prin1-to-string name))))

;;;###autoload
(defun cmacs-gowl-hotkey-define-function (name function)
  "Make FUNCTION reachable from hotkeys as NAME; return NAME.
A YAML hotkey's {call: NAME, args: [...]}, a C script's
`gowl_hotkey_call_function()' and `gowl-msg hotkey-call NAME ARGS' then
call FUNCTION with the arguments, as strings, on the main thread."
  (let ((name (cmacs-gowl-hotkey--word name "function name")))
    (unless (functionp function)
      (user-error "Hotkey function %s: %S is not a function" name function))
    (puthash name function cmacs-gowl-hotkey--named-functions)
    (when (cmacs-gowl-hotkey--running-p)
      (cmacs-gowl-hotkey-ensure)
      (cmacs-gowl-hotkey--send-function name))
    name))

(defun cmacs-gowl-hotkey-undefine-function (name)
  "Forget the Elisp hotkey function NAME."
  (remhash name cmacs-gowl-hotkey--named-functions)
  (when (and (cmacs-gowl-hotkey--running-p) cmacs-gowl-hotkey--enabled)
    (ignore-errors
      (cmacs-gowl-hotkey--command (concat "hotkey-func-undefine " name))))
  name)

(defun cmacs-gowl-hotkey--call-function (name args trigger)
  "Call the Elisp hotkey function NAME with ARGS; TRIGGER is bound."
  (let ((fn (gethash name cmacs-gowl-hotkey--named-functions))
        (cmacs-gowl-hotkey-current name)
        (cmacs-gowl-hotkey-trigger trigger))
    (if (not fn)
        (message "cmacs-gowl-hotkey: no Elisp function called %s" name)
      (condition-case err
          (apply fn args)
        (error (cmacs-gowl-hotkey--fault name (error-message-string err)))))))

;;;; Contexts

;;;###autoload
(defun cmacs-gowl-hotkey-define-context (name predicate)
  "Make PREDICATE the hotkey context NAME; return NAME.
PREDICATE is called with the focused window's `gowl-client-info' alist
\(or nil) whenever the focus or a title changes, and its answer --
true or false -- is what hotkeys with :context NAME see.  It is never
asked while a key is being decided, so it may be as slow as it likes;
it only cannot depend on something other than the focused window
without `cmacs-gowl-hotkey-refresh-contexts' being called."
  (let ((name (cmacs-gowl-hotkey--word name "context name")))
    (unless (functionp predicate)
      (user-error "Hotkey context %s: %S is not a function" name predicate))
    (puthash name predicate cmacs-gowl-hotkey--contexts)
    (remhash name cmacs-gowl-hotkey--context-values)
    (cmacs-gowl-hotkey--listen-contexts t)
    (when (cmacs-gowl-hotkey--running-p)
      (cmacs-gowl-hotkey-ensure)
      (cmacs-gowl-hotkey-refresh-contexts))
    name))

(defun cmacs-gowl-hotkey-undefine-context (name)
  "Forget the Elisp hotkey context NAME (it then never holds)."
  (remhash name cmacs-gowl-hotkey--contexts)
  (remhash name cmacs-gowl-hotkey--context-values)
  (when (and (cmacs-gowl-hotkey--running-p) cmacs-gowl-hotkey--enabled)
    (ignore-errors
      (cmacs-gowl-hotkey--command (concat "hotkey-context-clear " name))))
  (when (zerop (hash-table-count cmacs-gowl-hotkey--contexts))
    (cmacs-gowl-hotkey--listen-contexts nil))
  name)

(defun cmacs-gowl-hotkey-focused-window ()
  "The focused window's `gowl-client-info' alist, or nil."
  (let ((c (and (fboundp 'gowl-focused-client)
                (ignore-errors (gowl-focused-client)))))
    (and c (ignore-errors (gowl-client-info c)))))

(defun cmacs-gowl-hotkey-refresh-contexts ()
  "Ask every Elisp context again; push the answers that changed."
  (interactive)
  (setq cmacs-gowl-hotkey--context-timer nil)
  (when (and cmacs-gowl-hotkey--enabled (cmacs-gowl-hotkey--running-p)
             (> (hash-table-count cmacs-gowl-hotkey--contexts) 0))
    (let ((info (cmacs-gowl-hotkey-focused-window)))
      (maphash
       (lambda (name pred)
         (let ((value (condition-case err
                          (and (funcall pred info) t)
                        (error
                         (cmacs-gowl-hotkey--fault
                          name (format "context: %s" (error-message-string err)))
                         nil)))
               (old (gethash name cmacs-gowl-hotkey--context-values 'unset)))
           (unless (eq value old)
             (puthash name value cmacs-gowl-hotkey--context-values)
             (cmacs-gowl-hotkey--try (format "context %s" name)
               (cmacs-gowl-hotkey--command
                (format "hotkey-context-set %s %d" name (if value 1 0)))))))
       cmacs-gowl-hotkey--contexts))))

(defun cmacs-gowl-hotkey--refresh-soon (&rest _)
  "Refresh the contexts on the next turn of the main loop, once."
  (unless cmacs-gowl-hotkey--context-timer
    (setq cmacs-gowl-hotkey--context-timer
          (run-at-time 0 nil #'cmacs-gowl-hotkey-refresh-contexts))))

(defun cmacs-gowl-hotkey--listen-contexts (on)
  "Follow the focus and titles for the Elisp contexts (ON), or stop."
  (dolist (hook '(cmacs-gowl-focus-changed-functions
                  cmacs-gowl-client-title-changed-functions))
    (if on
        (add-hook hook #'cmacs-gowl-hotkey--refresh-soon)
      (remove-hook hook #'cmacs-gowl-hotkey--refresh-soon))))

;;;; Sections

(defun cmacs-gowl-hotkey--send-section (id data)
  "Send section DATA (YAML text or Lisp data) to the module under ID."
  (cmacs-gowl-hotkey--command
   (format "hotkey-add --id=%s %s" id (cmacs-gowl-hotkey-yaml data))))

;;;###autoload
(defun cmacs-gowl-hotkey-add-section (id data)
  "Install a whole `hotkey:' section, DATA, under ID; return ID.
DATA is YAML text or Lisp data (see `cmacs-gowl-hotkey-yaml'): modes,
timers, event hooks, functions, remaps -- anything the module reads.
Adding under the same ID again replaces it."
  (let ((id (cmacs-gowl-hotkey--word id "section id")))
    (cmacs-gowl-hotkey-yaml data)
    (setq cmacs-gowl-hotkey--sections
          (cons (cons id data)
                (assoc-delete-all id cmacs-gowl-hotkey--sections)))
    (when (cmacs-gowl-hotkey--running-p)
      (if cmacs-gowl-hotkey--enabled
          (cmacs-gowl-hotkey--send-section id data)
        (cmacs-gowl-hotkey-start)))
    id))

(defun cmacs-gowl-hotkey-remove-section (id)
  "Take back the section installed under ID."
  (setq cmacs-gowl-hotkey--sections
        (assoc-delete-all id cmacs-gowl-hotkey--sections))
  (when (and (cmacs-gowl-hotkey--running-p) cmacs-gowl-hotkey--enabled)
    (ignore-errors (cmacs-gowl-hotkey--command (concat "hotkey-remove " id))))
  id)

;;;; Commands

(defun cmacs-gowl-hotkey-status ()
  "The module's state as an alist; interactively, a summary."
  (interactive)
  (cmacs-gowl-hotkey-ensure)
  (let ((s (cmacs-gowl-hotkey--json "hotkey-status")))
    (when (called-interactively-p 'interactive)
      (message "Hotkey %s, mode %s -- %s hotkey(s), %s remap(s)%s"
               (if (alist-get 'suspended s) "SUSPENDED" "on")
               (or (alist-get 'mode s) "default")
               (alist-get 'hotkeys s) (alist-get 'remaps s)
               (if (alist-get 'last-error s)
                   (format "; last error: %s" (alist-get 'last-error s))
                 "")))
    s))

(defun cmacs-gowl-hotkey-list ()
  "Every hotkey and remap in force, as a list of alists."
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--json "hotkey-list"))

(defun cmacs-gowl-hotkey-problems ()
  "What the module could not use, as a list of strings; interactively, shown."
  (interactive)
  (cmacs-gowl-hotkey-ensure)
  (let ((p (cmacs-gowl-hotkey--json "hotkey-problems")))
    (when (called-interactively-p 'interactive)
      (if (null p) (message "Hotkey: no problems")
        (with-help-window "*gowl hotkey problems*"
          (dolist (line p) (princ line) (terpri)))))
    p))

;;;###autoload
(defun cmacs-gowl-hotkey-suspend (&optional arg)
  "Toggle suspending every hotkey; positive ARG suspends, else resumes.
AutoHotkey's Suspend; hotkeys with :suspend-exempt keep working."
  (interactive "P")
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command
   (concat "hotkey-suspend "
           (cond ((null arg) "toggle")
                 ((eq arg 'off) "off")
                 ((eq arg 'on) "on")
                 ((> (prefix-numeric-value arg) 0) "on")
                 (t "off")))))

(defun cmacs-gowl-hotkey-mode-enter (mode)
  "Enter the key mode MODE (\"default\" leaves every mode)."
  (interactive "sMode: ")
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command
   (concat "hotkey-mode " (cmacs-gowl-hotkey--word mode "mode"))))

(defun cmacs-gowl-hotkey-send (keys)
  "Type KEYS, in AutoHotkey's Send syntax, into the focused window.
\"^a{Delete}\", \"{Tab 3}\", \"{Shift down}x{Shift up}\", \"{U+00E9}\"."
  (interactive "sSend: ")
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command (concat "hotkey-send " keys)))

(defun cmacs-gowl-hotkey-send-text (text)
  "Type TEXT, literally, into the focused window."
  (interactive "sText: ")
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command (concat "hotkey-send-text " text)))

(defun cmacs-gowl-hotkey-fire (id)
  "Run hotkey ID's actions as if it had been pressed."
  (interactive
   (list (completing-read "Fire hotkey: "
                          (mapcar (lambda (h) (alist-get 'id h))
                                  (cmacs-gowl-hotkey-list))
                          nil t)))
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command (concat "hotkey-fire " id)))

(defun cmacs-gowl-hotkey-set-enabled (id enabled)
  "Switch hotkey ID on (ENABLED non-nil) or off, keeping it defined."
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command
   (format "hotkey-%s %s" (if enabled "enable" "disable") id)))

(defun cmacs-gowl-hotkey-call (name &rest args)
  "Call the hotkey function NAME with ARGS (strings); return its result.
Reaches YAML `functions:', C functions and Elisp ones alike."
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command
   (mapconcat #'identity
              (cons (concat "hotkey-call " (cmacs-gowl-hotkey--word name "name"))
                    (mapcar #'shell-quote-argument args))
              " ")))

(defun cmacs-gowl-hotkey-input (name &rest plist)
  "Start an input hook NAME; its end runs `cmacs-gowl-hotkey-input-functions'.
PLIST: :length N, :timeout MS, :visible B (keys still reach the window),
:case-sensitive B.  AutoHotkey's InputHook."
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command
   (string-join
    (delq nil
          (list "hotkey-input-start" (cmacs-gowl-hotkey--word name "input name")
                (and (plist-get plist :length)
                     (format "L%d" (plist-get plist :length)))
                (and (plist-get plist :timeout)
                     (format "T%d" (plist-get plist :timeout)))
                (and (plist-get plist :visible) "V")
                (and (plist-get plist :case-sensitive) "C")))
    " ")))

(defun cmacs-gowl-hotkey-history ()
  "The last inputs the module saw, as a list of alists; interactively, shown.
The first thing to look at when a hotkey does not fire."
  (interactive)
  (cmacs-gowl-hotkey-ensure)
  (let ((h (cmacs-gowl-hotkey--json "hotkey-history")))
    (when (called-interactively-p 'interactive)
      (with-help-window "*gowl hotkey history*"
        (dolist (e h)
          (princ (format "%-6s %-20s %-5s %s%s%s\n"
                         (or (alist-get 'code e) "")
                         (or (alist-get 'keysym e) (alist-get 'button e) "")
                         (if (alist-get 'pressed e) "down" "up")
                         (if (alist-get 'injected e) "injected " "")
                         (if (alist-get 'swallowed e) "swallowed " "")
                         (if (alist-get 'fired e)
                             (format "-> %s" (alist-get 'fired e))
                           ""))))))
    h))

(defun cmacs-gowl-hotkey-reload ()
  "Make the module read every source again."
  (interactive)
  (cmacs-gowl-hotkey-ensure)
  (cmacs-gowl-hotkey--command "hotkey-reload"))

;;;; Hearing the module

(defun cmacs-gowl-hotkey--set-state (what value)
  "Record WHAT (`suspended' or `mode') as VALUE, update the lighter, run the hook."
  (pcase what
    ('suspended (setq cmacs-gowl-hotkey--suspended value))
    ('mode (setq cmacs-gowl-hotkey--mode
                 (and value (not (equal value "default")) value))))
  (force-mode-line-update t)
  (run-hook-with-args 'cmacs-gowl-hotkey-changed-functions what
                      (if (eq what 'mode) (or value "default") value)))

(defun cmacs-gowl-hotkey--on-module-event (module text)
  "Handle a gowl `module-event' from MODULE carrying TEXT.
The hotkey module announces \"fired ID\", \"mode NAME\", \"suspended
on|off WHY\", \"input NAME REASON TEXT\" and \"fault TEXT\"."
  (when (equal module cmacs-gowl-hotkey--module)
    (let* ((text (or text ""))
           (words (split-string text " " t)))
      (pcase (car words)
        ("fired"
         (run-hook-with-args 'cmacs-gowl-hotkey-fired-functions
                             (string-trim (substring text 5))))
        ("mode" (cmacs-gowl-hotkey--set-state 'mode (or (cadr words) "default")))
        ("suspended"
         (cmacs-gowl-hotkey--set-state 'suspended (equal (cadr words) "on")))
        ((and "input" (guard (not (equal (nth 2 words) "started"))))
         (run-hook-with-args 'cmacs-gowl-hotkey-input-functions
                             (nth 1 words) (nth 2 words)
                             (string-join (nthcdr 3 words) " ")))
        ("fault"
         (cmacs-gowl-hotkey--fault nil (string-trim (substring text 5))))))))

(defun cmacs-gowl-hotkey--listen (on)
  "Listen to the module's events (ON non-nil), or stop."
  (if on
      (add-hook 'cmacs-gowl-module-event-functions
                #'cmacs-gowl-hotkey--on-module-event)
    (remove-hook 'cmacs-gowl-module-event-functions
                 #'cmacs-gowl-hotkey--on-module-event)))

(defun cmacs-gowl-hotkey--lighter ()
  "The mode-line text while suspended or in a mode, or nil."
  (and cmacs-gowl-hotkey-lighter
       (or cmacs-gowl-hotkey--suspended cmacs-gowl-hotkey--mode)
       (propertize
        (concat cmacs-gowl-hotkey-lighter ":"
                (if cmacs-gowl-hotkey--suspended "off" cmacs-gowl-hotkey--mode))
        'face (if cmacs-gowl-hotkey--suspended 'shadow 'warning)
        'help-echo (if cmacs-gowl-hotkey--suspended
                       (format "Hotkeys suspended; %s resumes"
                               (or cmacs-gowl-hotkey-suspend-key
                                   "M-x cmacs-gowl-hotkey-suspend"))
                     (format "Hotkey mode %s" cmacs-gowl-hotkey--mode)))))

(defconst cmacs-gowl-hotkey--mode-line-entry
  '(:eval (cmacs-gowl-hotkey--lighter))
  "The `mode-line-misc-info' entry for the hotkey module.")

(add-to-list 'mode-line-misc-info cmacs-gowl-hotkey--mode-line-entry t)

;;;; A buffer of hotkeys

(defvar-keymap cmacs-gowl-hotkey-list-mode-map
  :doc "Keys in the hotkey buffer."
  "f" #'cmacs-gowl-hotkey-fire-at-point
  "t" #'cmacs-gowl-hotkey-toggle-at-point
  "s" #'cmacs-gowl-hotkey-suspend
  "h" #'cmacs-gowl-hotkey-history
  "P" #'cmacs-gowl-hotkey-problems)

(define-derived-mode cmacs-gowl-hotkey-list-mode tabulated-list-mode
  "Hotkeys"
  "Every hotkey in force.
\\<cmacs-gowl-hotkey-list-mode-map>
\\[cmacs-gowl-hotkey-fire-at-point] fires the hotkey at point, \\[cmacs-gowl-hotkey-toggle-at-point] switches it on or off, \\[cmacs-gowl-hotkey-suspend]
suspends them all, \\[cmacs-gowl-hotkey-history] shows the key history, \\[cmacs-gowl-hotkey-problems] what the module could not
use, and \\[revert-buffer] refreshes."
  (setq tabulated-list-format
        [("Key" 18 t) ("Id" 24 t) ("On" 3 t) ("Mode" 10 t) ("Context" 14 t)
         ("Description" 0 t)])
  (add-hook 'tabulated-list-revert-hook
            #'cmacs-gowl-hotkey--buffer-refresh nil t)
  (tabulated-list-init-header))

(defun cmacs-gowl-hotkey--buffer-refresh ()
  "Fill the hotkey buffer from the module."
  (setq tabulated-list-entries
        (cl-loop for h in (cmacs-gowl-hotkey-list)
                 when (alist-get 'id h)
                 collect (list (alist-get 'id h)
                               (vector (format "%s" (or (alist-get 'canonical h)
                                                        (alist-get 'key h) ""))
                                       (alist-get 'id h)
                                       (if (alist-get 'enabled h) "yes" "no")
                                       (format "%s" (or (alist-get 'mode h) ""))
                                       (format "%s" (or (alist-get 'context h) ""))
                                       (format "%s" (or (alist-get 'description h)
                                                        "")))))))

(defun cmacs-gowl-hotkey-fire-at-point ()
  "Fire the hotkey at point."
  (interactive)
  (cmacs-gowl-hotkey-fire (or (tabulated-list-get-id)
                              (user-error "No hotkey on this line"))))

(defun cmacs-gowl-hotkey-toggle-at-point ()
  "Switch the hotkey at point on or off."
  (interactive)
  (let ((id (or (tabulated-list-get-id) (user-error "No hotkey on this line"))))
    (cmacs-gowl-hotkey--command (concat "hotkey-toggle " id))
    (revert-buffer)))

;;;###autoload
(defun cmacs-gowl-hotkey-show ()
  "List every hotkey in force."
  (interactive)
  (cmacs-gowl-hotkey-ensure)
  (with-current-buffer (get-buffer-create "*gowl hotkeys*")
    (cmacs-gowl-hotkey-list-mode)
    (cmacs-gowl-hotkey--buffer-refresh)
    (tabulated-list-print)
    (pop-to-buffer (current-buffer))))

;;;; RPC (D-Bus, MCP)

(defconst cmacs-gowl-hotkey--rpc-verbs
  '("status" "list" "problems" "add" "remove" "enable" "disable" "toggle"
    "fire" "suspend" "mode" "send" "send-text" "call" "history" "keystate"
    "capslock" "numlock" "timers" "functions" "contexts" "reload" "cancel"
    "help")
  "The module verbs `cmacs-gowl-hotkey-rpc' passes on.
Mirrors the whitelist in `cmacs_dispatch_gowl_hotkey' (cmacs/glib).")

(defun cmacs-gowl-hotkey-rpc (verb &optional args)
  "Run hotkey VERB with ARGS (one line, or nil) for an RPC caller.
Never signals.  VERB is one of `cmacs-gowl-hotkey--rpc-verbs', the
module's command words without `hotkey-'.  Returns \"OK ...\" or
\"ERROR ...\"."
  (cond ((not (member verb cmacs-gowl-hotkey--rpc-verbs))
         (format "ERROR unknown hotkey verb %s" verb))
        ((and args (string-match-p "[\n\r]" args))
         "ERROR hotkey arguments must be one line")
        (t (cmacs-gowl-hotkey-command
            (concat "hotkey-" verb
                    (and args (not (string-empty-p args)) (concat " " args)))))))

(defun cmacs-gowl-hotkey-command (line)
  "Run the module command LINE (\"hotkey-...\"); return its reply.
For MCP and D-Bus: an error comes back as \"ERROR ...\" text, never a
signal.  Loads the module first."
  (condition-case err
      (if (not (string-prefix-p "hotkey-" line))
          "ERROR not a hotkey- command"
        (cmacs-gowl-hotkey-ensure)
        (let ((reply (cmacs-gowl-hotkey--command line)))
          (if (string-empty-p reply) "OK" (concat "OK " reply))))
    (error (concat "ERROR " (error-message-string err)))))

;;;; Startup

(defun cmacs-gowl-hotkey--configured-p ()
  "Non-nil when anything asks for the module."
  (or cmacs-gowl-hotkey-enable cmacs-gowl-hotkey-definitions
      cmacs-gowl-hotkey-remaps cmacs-gowl-hotkey-hotstrings
      cmacs-gowl-hotkey-section cmacs-gowl-hotkey-scripts
      cmacs-gowl-hotkey--defined cmacs-gowl-hotkey--sections
      (> (hash-table-count cmacs-gowl-hotkey--named-functions) 0)
      (> (hash-table-count cmacs-gowl-hotkey--contexts) 0)))

(defun cmacs-gowl-hotkey--on-start ()
  "Install the module and everything configured, if asked to.
Called by `cmacs-gowl-mode' when the compositor (re)starts.  Does
nothing, and loads nothing, unless the module is enabled or something
is configured or defined."
  (setq cmacs-gowl-hotkey--enabled nil
        cmacs-gowl-hotkey--suspended nil
        cmacs-gowl-hotkey--mode nil)
  (dolist (d cmacs-gowl-hotkey-definitions)
    (let ((id (or (plist-get (cddr d) :id) (car d))))
      (unless (assoc id cmacs-gowl-hotkey--defined)
        (cmacs-gowl-hotkey--try (format "hotkey %s" (car d))
          (apply #'cmacs-gowl-hotkey-entry (car d) (cadr d) (cddr d))
          (when (cadr d)
            (puthash id (cadr d) cmacs-gowl-hotkey--functions))
          (push (cl-list* id (car d) (cadr d) (cddr d))
                cmacs-gowl-hotkey--defined)))))
  (when (cmacs-gowl-hotkey--configured-p)
    (cmacs-gowl-hotkey--try "start"
      (cmacs-gowl-hotkey-start))))

(provide 'cmacs-gowl-hotkey)

;;; cmacs-gowl-hotkey.el ends here
