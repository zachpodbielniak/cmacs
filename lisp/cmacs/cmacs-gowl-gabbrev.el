;;; cmacs-gowl-gabbrev.el --- Text expansion in gowl, configured from Elisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `gabbrev' module is a text expander -- espanso, done in the
;; compositor, named for `abbrev-mode'.  Type ";today" in any window and
;; it becomes "2026-10-19"; ";shrug" becomes the shrug; ";reword" at the
;; end of a line has cmacs-ai rewrite the line in place.  The module's
;; reference is deps/gowl/docs/gabbrev.org; this file is its Elisp
;; surface under `cmacs --gowl', where the module is always loaded.
;;
;; CONFIGURE IT FROM YOUR INIT FILE:
;;
;;   (setq cmacs-gowl-gabbrev-espanso t)             ; ~/.config/espanso too
;;   (setq cmacs-gowl-gabbrev-files '("~/notes/snippets.yml"))
;;   (setq cmacs-gowl-gabbrev-options '((toggle_key . "ALT")))
;;
;;   (cmacs-gowl-gabbrev-define ";sig" "Best,\nZach")
;;   (cmacs-gowl-gabbrev-define "teh" "the" :word t :propagate-case t)
;;   (cmacs-gowl-gabbrev-define ";cal"
;;     (lambda (_ctx) (format-time-string "%A %e %B")))
;;
;; A replacement that is a FUNCTION is Elisp run to fill it in -- the
;; module asks for it through a C callback (`gowl-gabbrev-register-type'
;; in cmacs-gowl.c) that queues it on Emacs's main thread.  Lisp is only
;; ever defined here, from Elisp; YAML can CALL what was defined here by
;; name, never define it:
;;
;;   (cmacs-gowl-gabbrev-define-function "weather" #'my-weather)
;;     ;; YAML: vars: [{name: w, type: elisp, params: {function: weather}}]
;;
;;   (cmacs-gowl-gabbrev-define-type "ticket" #'my-ticket-lookup)
;;     ;; YAML: vars: [{name: t, type: ticket, params: {id: "{{n}}"}}]
;;
;; Every such function gets a context (`cmacs-gowl-gabbrev-param',
;; `cmacs-gowl-gabbrev-var', `cmacs-gowl-gabbrev-context-trigger', ...)
;; and returns a string -- or `:async', and answers later with
;; `cmacs-gowl-gabbrev-answer' or `cmacs-gowl-gabbrev-fail'.  The calls
;; run inside the RPC dispatcher, which forbids prompting
;; (`inhibit-interaction'); anything that asks the user goes through a
;; timer and `:async', as the pickers below do.
;;
;; ABBREV-MODE: the abbrev tables in `cmacs-gowl-gabbrev-abbrev-tables'
;; (the global one by default) are expanded in every window, the way
;; abbrev-mode expands them in a buffer -- as whole words, keeping case,
;; hooks included -- and kept in step when an abbrev is defined.  And
;; the other way: `cmacs-gowl-gabbrev-emacs-mode' expands gabbrev's
;; triggers inside Emacs buffers, through the same renderer, so a
;; snippet is one definition everywhere.  Emacs's own frames are left
;; out of the compositor-side expansion (that is what the mode is for)
;; unless `cmacs-gowl-gabbrev-in-emacs' says otherwise.
;;
;; Pickers -- a `choice' variable, a form, the search -- are the
;; minibuffer here, instead of the module's dmenu-style program.
;;
;; Everything reaches the module through `gowl-run-command' and its
;; `gabbrev-' commands (the IPC words), and hears it through
;; `cmacs-gowl-module-event-functions'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'abbrev)
(require 'tabulated-list)

(declare-function gowl-run-command "cmacs-gowl")
(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-enable-module "cmacs-gowl")
(declare-function gowl-configure-module "cmacs-gowl")
(declare-function gowl-add-keybind "cmacs-gowl")
(declare-function gowl-gabbrev-register-type "cmacs-gowl.c" (type))
(declare-function gowl-gabbrev-unregister-type "cmacs-gowl.c" (type))
(declare-function cmacs-ai-make-session "cmacs-ai")
(declare-function cmacs-gowl-macro-ensure "cmacs-gowl-macro" ())
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c" (session prompt callback))
(defvar cmacs-gowl-module-event-functions)

(defgroup cmacs-gowl-gabbrev nil
  "Text expansion in every window: gowl's gabbrev module."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-gabbrev-")

(defconst cmacs-gowl-gabbrev--module "gabbrev"
  "The gowl module's name.")

;;;; Options

(defcustom cmacs-gowl-gabbrev-enable t
  "Non-nil: expand from the start.  `cmacs-gowl-gabbrev-toggle' flips it."
  :type 'boolean
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-builtin t
  "Non-nil: load gabbrev's shipped matches (;today, ;htoday, ;shrug, ...).
Any match of yours with the same trigger replaces the shipped one;
`cmacs-gowl-gabbrev-list' shows them all."
  :type 'boolean
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-files nil
  "Match files, directories of them, or espanso configuration directories.
Each is loaded after the shipped matches and before your Elisp ones, so
`cmacs-gowl-gabbrev-define' wins a trigger they share.  `~/' is fine."
  :type '(repeat (choice file directory))
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-espanso 'auto
  "Whether to load an espanso configuration as it is.
`auto' (the default) loads $XDG_CONFIG_HOME/espanso when it exists; t
loads it whether or not (a missing one is reported); nil never; a
directory loads that one."
  :type '(choice (const :tag "When ~/.config/espanso exists" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil)
                 directory)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-options nil
  "espanso options, as an alist of (NAME . VALUE).
NAME is espanso's option name as a symbol or string (`toggle_key',
`backend', `clipboard_threshold', `word_separators', ...); VALUE a
string, number, t, `:false', or a list.  See \"Options\" in
deps/gowl/docs/gabbrev.org."
  :type '(alist :key-type (choice symbol string) :value-type sexp)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-matches nil
  "Matches, as plists, loaded with those of `cmacs-gowl-gabbrev-define'.
Each is (:trigger \";x\" :replace \"text\" ...) with the YAML keys as
keywords (`:propagate-case', `:word', `:vars', `:filter', ...); see
`cmacs-gowl-gabbrev-define' for the shorthand."
  :type '(repeat plist)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-in-emacs nil
  "Non-nil: the compositor expands into Emacs's own frames too.
nil (the default) leaves Emacs to itself: there `abbrev-mode' and
`cmacs-gowl-gabbrev-emacs-mode' expand, as buffer edits with undo,
instead of Backspaces typed at whatever the keys mean in the current
mode (evil's normal state, a dired buffer, ...)."
  :type 'boolean
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-deny-filter nil
  "Windows nothing is expanded into, in gowl's filter language, or nil.
nil keeps the module's default (password managers, pinentry, polkit,
anything titled like a password prompt).  A string starting with `+'
adds to that default; any other replaces it; \"none\" switches it off.
Emacs's own frames are added unless `cmacs-gowl-gabbrev-in-emacs'."
  :type '(choice (const :tag "The module's default" nil) string)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-search-key "Super+Alt+e"
  "The gowl key that expands what was just typed, or nil for none.
When the text before the cursor ends with a trigger it expands at once,
word rules or not.  Otherwise it opens the search, starting from the
word being typed, and the match picked replaces that word."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-toggle-key nil
  "espanso's toggle key: a modifier pressed twice alone (\"ALT\"), or a chord.
nil leaves `toggle_key' to `cmacs-gowl-gabbrev-options' and the files."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-use-minibuffer t
  "Non-nil: `choice' variables, forms and the search use the minibuffer.
nil leaves them to the module's dmenu-style picker (fuzzel, bemenu...)."
  :type 'boolean
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-ai-rewrite t
  "Non-nil: ;reword and ;fix use cmacs-ai instead of the `ai' command."
  :type 'boolean
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-ai-provider nil
  "The cmacs-ai provider ;reword and ;fix use; nil for the default."
  :type '(choice (const :tag "Default" nil) symbol)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-ai-model nil
  "The model ;reword and ;fix use; nil for the provider's default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-ai-actions
  '((";reword" "Reword the current line with AI"
     "Reword the text you are given. Keep its meaning, language, register and formatting. Reply with the reworded text only.")
    (";fix" "Fix spelling and grammar on the current line with AI"
     "Correct the spelling, grammar and punctuation of the text you are given and change nothing else. Reply with the corrected text only."))
  "Grab-rewrite-paste triggers: (TRIGGER LABEL SYSTEM-PROMPT [SCOPE]).
Typing TRIGGER selects text behind the cursor (SCOPE: `line', the
default, `word', `paragraph' or `all'), has cmacs-ai rewrite it with
SYSTEM-PROMPT, and pastes the answer over it."
  :type '(repeat (list string string string
                       (choice (const :tag "Line" nil) (const line)
                               (const word) (const paragraph) (const all))))
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-abbrev-tables '(global-abbrev-table)
  "Abbrev tables whose abbrevs expand in every window, or nil for none.
Each is a symbol naming an abbrev table.  They expand as abbrev-mode
expands them: as whole words, following the case typed unless the
table or abbrev is `:case-fixed', running the abbrev's hook."
  :type '(repeat symbol)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-abbrev-prefix ""
  "Text before an abbrev's name that triggers it outside Emacs.
\"\" (the default) is abbrev-mode's own behaviour: the bare word."
  :type 'string
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-abbrev-include-system nil
  "Non-nil: also export abbrevs marked `:system' (modes' own)."
  :type 'boolean
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-module-settings nil
  "More `modules: gabbrev:' settings, as an alist of strings.
For example ((\"picker-command\" . \"fuzzel --dmenu\") (\"log\" . \"true\"))."
  :type '(alist :key-type string :value-type string)
  :group 'cmacs-gowl-gabbrev)

(defcustom cmacs-gowl-gabbrev-expanded-functions nil
  "Functions run with a match's id after the module typed it."
  :type 'hook
  :group 'cmacs-gowl-gabbrev)

;;;; Registries

(defvar cmacs-gowl-gabbrev--functions (make-hash-table :test #'equal)
  "Name -> function, for `type: elisp, params: {function: NAME}'.")

(defvar cmacs-gowl-gabbrev--types (make-hash-table :test #'equal)
  "Variable type -> function, for types defined in Lisp.")

(defvar cmacs-gowl-gabbrev--defined nil
  "Matches from `cmacs-gowl-gabbrev-define', newest first, as plists.")

(defvar cmacs-gowl-gabbrev--push-timer nil
  "Pending push of the Elisp matches (definitions come in bursts).")

(defvar cmacs-gowl-gabbrev--triggers nil
  "Cached (TRIGGER ID LEFT-WORD RIGHT-WORD) for the in-buffer mode.")

(defvar cmacs-gowl-gabbrev-emacs-mode)

;;;; Talking to the module

(defun cmacs-gowl-gabbrev--running-p ()
  "Non-nil when a gowl compositor is running in this Emacs."
  (and (fboundp 'gowl-running-p) (gowl-running-p)))

(defun cmacs-gowl-gabbrev--command (line &optional quiet)
  "Run the module command LINE; return the text after \"OK \".
An ERROR reply is a `user-error' (or, with QUIET, nil)."
  (let ((reply (cond ((cmacs-gowl-gabbrev--running-p) (gowl-run-command line))
                     (quiet nil)
                     (t (user-error "Gowl compositor is not running")))))
    (cond ((null reply)
           (unless quiet
             (user-error "The gowl gabbrev module is not loaded")))
          ((string-prefix-p "ERROR" reply)
           (unless quiet
             (user-error "gabbrev: %s" (string-trim (substring reply 5)))))
          ((string-prefix-p "OK " reply) (substring reply 3))
          ((equal reply "OK") "")
          (t reply))))

(defun cmacs-gowl-gabbrev--json (text)
  "Parse the module's JSON TEXT into alists and lists."
  (json-parse-string text :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun cmacs-gowl-gabbrev--encode (value)
  "VALUE as one line of JSON (YAML is a superset, so the module reads it).
A plist (keyword first) or alist becomes an object, with `-' in keys
spelled `_' as espanso does; a list of objects an array; t true;
`:false' false."
  (json-encode (cmacs-gowl-gabbrev--jsonable value)))

(defun cmacs-gowl-gabbrev--key (k)
  "K, a keyword, symbol or string, as an espanso key."
  (replace-regexp-in-string
   "-" "_" (if (keywordp k) (substring (symbol-name k) 1) (format "%s" k))))

(defun cmacs-gowl-gabbrev--jsonable (v)
  "V, as `json-encode' should see it: hash tables and vectors."
  (cond
   ((eq v t) t)
   ((eq v :false) :json-false)
   ((null v) :json-false)
   ((or (stringp v) (numberp v)) v)
   ((symbolp v) (symbol-name v))
   ((and (consp v) (keywordp (car v)))
    (let ((h (make-hash-table :test #'equal)))
      (cl-loop for (k val) on v by #'cddr
               unless (null val)
               do (puthash (cmacs-gowl-gabbrev--key k)
                           (cmacs-gowl-gabbrev--jsonable val) h))
      h))
   ((and (consp v) (consp (car v)) (not (proper-list-p (car v))))
    ;; an alist with dotted pairs
    (let ((h (make-hash-table :test #'equal)))
      (dolist (pair v)
        (puthash (cmacs-gowl-gabbrev--key (car pair))
                 (cmacs-gowl-gabbrev--jsonable (cdr pair)) h))
      h))
   ((consp v) (vconcat (mapcar #'cmacs-gowl-gabbrev--jsonable v)))
   ((vectorp v) (vconcat (mapcar #'cmacs-gowl-gabbrev--jsonable v)))
   (t (format "%s" v))))

;;;; Contexts: what a Lisp variable function is told

(cl-defstruct (cmacs-gowl-gabbrev-context
               (:constructor cmacs-gowl-gabbrev--make-context)
               (:copier nil))
  "One variable waiting for its value."
  id type name params vars trigger app-id title)

(defun cmacs-gowl-gabbrev-param (ctx key &optional default)
  "CTX's param KEY (a string or symbol), or DEFAULT."
  (let ((cell (assoc (format "%s" key) (cmacs-gowl-gabbrev-context-params ctx)
                     (lambda (a b) (equal (format "%s" a) b)))))
    (if cell (cdr cell) default)))

(defun cmacs-gowl-gabbrev-var (ctx name)
  "The value of the variable NAME resolved before CTX's, or nil."
  (cdr (assoc (format "%s" name) (cmacs-gowl-gabbrev-context-vars ctx)
              (lambda (a b) (equal (format "%s" a) b)))))

(defun cmacs-gowl-gabbrev-answer (ctx value)
  "Answer CTX's variable with VALUE, a string.  Any time, once."
  (cmacs-gowl-gabbrev--command
   (format "gabbrev-resolve %d %s" (cmacs-gowl-gabbrev-context-id ctx)
           (json-encode (format "%s" (or value ""))))
   t))

(defun cmacs-gowl-gabbrev-fail (ctx message)
  "Fail CTX's variable, saying MESSAGE.  The expansion is dropped."
  (cmacs-gowl-gabbrev--command
   (format "gabbrev-resolve-error %d %s" (cmacs-gowl-gabbrev-context-id ctx)
           (replace-regexp-in-string "\n" " " (format "%s" message)))
   t))

(defun cmacs-gowl-gabbrev--deliver (ctx result)
  "Answer CTX with what a variable function returned."
  (cond ((eq result :async) nil)
        ((null result) (cmacs-gowl-gabbrev-answer ctx ""))
        ((stringp result) (cmacs-gowl-gabbrev-answer ctx result))
        (t (cmacs-gowl-gabbrev-answer ctx (format "%s" result)))))

(defun cmacs-gowl-gabbrev--resolve (id type name params-json vars-json
                                       trigger app-id title)
  "Resolve variable request ID, of TYPE, for the module.
Called on Emacs's main thread by the C callback behind
`gowl-gabbrev-register-type'.  NAME is the variable's name; PARAMS-JSON
and VARS-JSON its params and the values before it; TRIGGER, APP-ID and
TITLE what was typed, and where.  An error here fails the request."
  (let* ((ctx (cmacs-gowl-gabbrev--make-context
               :id id :type type :name name
               :params (cmacs-gowl-gabbrev--json params-json)
               :vars (cmacs-gowl-gabbrev--json vars-json)
               :trigger trigger :app-id app-id :title title))
         (fn (if (equal type "elisp")
                 (let ((fname (or (cmacs-gowl-gabbrev-param ctx "function")
                                  (cmacs-gowl-gabbrev-param ctx "name"))))
                   (or (gethash fname cmacs-gowl-gabbrev--functions)
                       (error "No Elisp function `%s' was defined with \
cmacs-gowl-gabbrev-define-function" fname)))
               (or (gethash type cmacs-gowl-gabbrev--types)
                   (error "No Lisp gabbrev type `%s'" type)))))
    (cmacs-gowl-gabbrev--deliver ctx (funcall fn ctx))
    t))

;;;; Defining things

(defun cmacs-gowl-gabbrev-define-function (name function)
  "Make FUNCTION callable from any gabbrev YAML as NAME.
A variable `{type: elisp, params: {function: NAME}}' calls FUNCTION
with its context and takes the string it returns (or `:async' and a
later `cmacs-gowl-gabbrev-answer').  This is the only way Lisp gets
into gabbrev: YAML names it, Elisp defines it."
  (puthash name function cmacs-gowl-gabbrev--functions)
  (cmacs-gowl-gabbrev--register-elisp)
  name)

(defun cmacs-gowl-gabbrev--register-elisp ()
  "Put the `elisp' type in libgowl's registry (idempotent)."
  (when (fboundp 'gowl-gabbrev-register-type)
    (gowl-gabbrev-register-type "elisp")))

(defun cmacs-gowl-gabbrev-define-type (type function)
  "Make TYPE a gabbrev variable type answered by FUNCTION.
FUNCTION gets the context of every variable of the type, from any
source (YAML included), and returns its value as
`cmacs-gowl-gabbrev-define-function' describes.  A TYPE the module has
built in (\"choice\", \"form\", ...) is replaced while defined."
  (puthash type function cmacs-gowl-gabbrev--types)
  (when (fboundp 'gowl-gabbrev-register-type)
    (gowl-gabbrev-register-type type))
  type)

(defun cmacs-gowl-gabbrev-undefine-type (type)
  "Stop answering TYPE from Lisp."
  (remhash type cmacs-gowl-gabbrev--types)
  (when (fboundp 'gowl-gabbrev-unregister-type)
    (gowl-gabbrev-unregister-type type)))

(defun cmacs-gowl-gabbrev--function-name (trigger)
  "The registry name a function replacement for TRIGGER gets."
  (concat "lisp:" trigger))

(defun cmacs-gowl-gabbrev--match-spec (trigger replacement props)
  "A match plist for TRIGGER: REPLACEMENT a string or a function, PROPS more."
  (if (functionp replacement)
      (let ((fname (cmacs-gowl-gabbrev--function-name trigger)))
        (cmacs-gowl-gabbrev-define-function fname replacement)
        (append (list :trigger trigger :replace "{{value}}"
                      :vars (list (list :name "value" :type "elisp"
                                        :params (list :function fname))))
                props))
    (append (list :trigger trigger :replace replacement) props)))

;;;###autoload
(defun cmacs-gowl-gabbrev-define (trigger replacement &rest props)
  "Expand TRIGGER into REPLACEMENT in every window.
REPLACEMENT is the text -- with {{var}} placeholders, $|$ for the
cursor -- or a function of one argument (a context) returning it,
run on Emacs's main thread when TRIGGER is typed.  PROPS are the
match's other keys as keywords: `:word', `:left-word', `:right-word',
`:propagate-case', `:label', `:vars' (a list of plists), `:filter'
\(gowl's filter language: \"app-id ~ firefox\"), `:force-mode',
`:delete-first', `:timeout', ...  Defining TRIGGER again replaces it.

  (cmacs-gowl-gabbrev-define \";sig\" \"Best,\\nZach\")
  (cmacs-gowl-gabbrev-define \"teh\" \"the\" :word t :propagate-case t)
  (cmacs-gowl-gabbrev-define \";buf\" (lambda (_) (buffer-name)))"
  (setq cmacs-gowl-gabbrev--defined
        (cons (cmacs-gowl-gabbrev--match-spec trigger replacement props)
              (cl-remove-if (lambda (m) (equal (plist-get m :trigger) trigger))
                            cmacs-gowl-gabbrev--defined)))
  (cmacs-gowl-gabbrev--schedule-push)
  trigger)

(defun cmacs-gowl-gabbrev-undefine (trigger)
  "Forget the match `cmacs-gowl-gabbrev-define' made for TRIGGER."
  (setq cmacs-gowl-gabbrev--defined
        (cl-remove-if (lambda (m) (equal (plist-get m :trigger) trigger))
                      cmacs-gowl-gabbrev--defined))
  (remhash (cmacs-gowl-gabbrev--function-name trigger)
           cmacs-gowl-gabbrev--functions)
  (cmacs-gowl-gabbrev--schedule-push))

(defun cmacs-gowl-gabbrev--schedule-push ()
  "Push the Elisp matches soon (a burst of definitions pushes once)."
  (when (cmacs-gowl-gabbrev--running-p)
    (when (timerp cmacs-gowl-gabbrev--push-timer)
      (cancel-timer cmacs-gowl-gabbrev--push-timer))
    (setq cmacs-gowl-gabbrev--push-timer
          (run-with-idle-timer 0.2 nil #'cmacs-gowl-gabbrev--push-lisp))))

;;;; AI: grab, rewrite, put back

(defun cmacs-gowl-gabbrev--ai-function (system)
  "A variable function that rewrites the grabbed text with SYSTEM."
  (lambda (ctx)
    (let ((text (cmacs-gowl-gabbrev-var ctx "text")))
      (if (or (null text) (string-blank-p text))
          (progn (cmacs-gowl-gabbrev-fail ctx "nothing to rewrite") :async)
        (condition-case err
            (let* ((pair (cmacs-ai-make-session cmacs-gowl-gabbrev-ai-provider
                                                cmacs-gowl-gabbrev-ai-model
                                                system))
                   (acc ""))
              (cmacs-ai-chat-stream
               (cdr pair) text
               (lambda (payload)
                 (pcase (car-safe payload)
                   (:delta (setq acc (concat acc (or (cadr payload) ""))))
                   (:end
                    (let ((final (plist-get (cdr payload) :text)))
                      (cmacs-gowl-gabbrev-answer
                       ctx (string-trim (if (and final (> (length final)
                                                          (length acc)))
                                            final acc)))))
                   (:error
                    (cmacs-gowl-gabbrev-fail ctx (or (cadr payload)
                                                     "the model failed"))))))
              :async)
          (error (cmacs-gowl-gabbrev-fail ctx (error-message-string err))
                 :async))))))

(defun cmacs-gowl-gabbrev--ai-matches ()
  "Matches for `cmacs-gowl-gabbrev-ai-actions', when cmacs-ai is here."
  (when (and cmacs-gowl-gabbrev-ai-rewrite
             (or (fboundp 'cmacs-ai-make-session)
                 (require 'cmacs-ai nil t))
             (fboundp 'cmacs-ai-chat-stream))
    (mapcar
     (lambda (action)
       (pcase-let ((`(,trigger ,label ,system ,scope) action))
         (let ((fname (concat "ai:" trigger)))
           (cmacs-gowl-gabbrev-define-function
            fname (cmacs-gowl-gabbrev--ai-function system))
           (list :trigger trigger :label label :delete-first t
                 :force-mode "clipboard" :timeout 120000
                 :replace "{{out}}"
                 :vars (list (list :name "text" :type "selection"
                                   :params (list :scope (symbol-name
                                                         (or scope 'line))))
                             (list :name "out" :type "elisp"
                                   :params (list :function fname)))))))
     cmacs-gowl-gabbrev-ai-actions)))

;;;; Pickers in the minibuffer

(defun cmacs-gowl-gabbrev--later (ctx thunk)
  "Run THUNK from a timer, answering CTX with its value; return `:async'.
Prompting is not allowed inside the RPC dispatcher, so pickers wait for
the command loop.  THUNK returning `:async' answers CTX itself, later.
Quitting the minibuffer fails the variable."
  (run-at-time
   0 nil
   (lambda ()
     (condition-case err
         (progn
           (when (frame-live-p (selected-frame))
             (select-frame-set-input-focus (selected-frame)))
           (let ((value (funcall thunk)))
             (unless (eq value :async)
               (cmacs-gowl-gabbrev-answer ctx value))))
       (quit (cmacs-gowl-gabbrev-fail ctx "cancelled"))
       (error (cmacs-gowl-gabbrev-fail ctx (error-message-string err))))))
  :async)

(defun cmacs-gowl-gabbrev--choices (values)
  "VALUES of a choice, as ((LABEL . ID) ...)."
  (mapcar (lambda (v)
            (if (consp v)
                (let ((label (alist-get 'label v))
                      (id (alist-get 'id v)))
                  (cons (format "%s" (or label id)) (format "%s" (or id label))))
              (cons (format "%s" v) (format "%s" v))))
          (if (stringp values) (split-string values "\n" t) values)))

(defun cmacs-gowl-gabbrev--choice-type (ctx)
  "A `choice' variable, in the minibuffer."
  (let ((choices (cmacs-gowl-gabbrev--choices
                  (cmacs-gowl-gabbrev-param ctx "values"))))
    (if (= (length choices) 1)
        (cdar choices)
      (cmacs-gowl-gabbrev--later
       ctx (lambda ()
             (let ((pick (completing-read "Choose: " choices nil t)))
               (or (cdr (assoc pick choices)) pick)))))))

(defun cmacs-gowl-gabbrev--form-type (ctx)
  "A `form' variable: one minibuffer question per [[field]], in order."
  (let* ((layout (or (cmacs-gowl-gabbrev-param ctx "layout") ""))
         (specs (cmacs-gowl-gabbrev-param ctx "fields"))
         (names (let ((pos 0) out)
                  (while (string-match "\\[\\[\\s-*\\([[:alnum:]_-]+\\)\\s-*\\]\\]"
                                       layout pos)
                    (cl-pushnew (match-string 1 layout) out :test #'equal)
                    (setq pos (match-end 0)))
                  (nreverse out))))
    (cmacs-gowl-gabbrev--later
     ctx
     (lambda ()
       (let ((answers (make-hash-table :test #'equal)))
         (dolist (name names)
           (let* ((spec (cdr (assoc name specs
                                    (lambda (a b) (equal (format "%s" a) b)))))
                  (type (alist-get 'type spec))
                  (default (alist-get 'default spec))
                  (values (alist-get 'values spec)))
             (puthash name
                      (if (member type '("choice" "list"))
                          (completing-read (format "%s: " name)
                                           (mapcar #'car
                                                   (cmacs-gowl-gabbrev--choices values))
                                           nil (equal type "choice") nil nil default)
                        (read-string (format "%s: " name) nil nil default))
                      answers)))
         (json-encode answers))))))

(defvar cmacs-gowl-gabbrev--searches (make-hash-table :test #'equal)
  "Render id -> the context of the search waiting for it.")

(defun cmacs-gowl-gabbrev--search-type (ctx)
  "The search: pick a match in the minibuffer; its rendered text answers."
  (cmacs-gowl-gabbrev--later
   ctx
   (lambda ()
     (let* ((matches (cmacs-gowl-gabbrev-list-matches))
            (rows (delq nil
                        (mapcar (lambda (m)
                                  (let ((trig (car (alist-get 'triggers m))))
                                    (when (and trig (not (alist-get 'overridden m)))
                                      (cons (format "%s  %s" trig
                                                    (or (alist-get 'label m)
                                                        (truncate-string-to-width
                                                         (or (alist-get 'replace m) "")
                                                         60)))
                                            (alist-get 'id m)))))
                                matches)))
            ;; Start from the word that was being typed (`;dat')
            (pick (completing-read "Expand: " rows nil t
                                   (cmacs-gowl-gabbrev-param ctx "query")))
            (id (cdr (assoc pick rows)))
            (rid (format "search-%d" (cmacs-gowl-gabbrev-context-id ctx))))
       (puthash rid ctx cmacs-gowl-gabbrev--searches)
       (cmacs-gowl-gabbrev--command (format "gabbrev-render --id %s %s" rid id))
       ;; Answered when the render arrives, as a module event
       :async))))

(defun cmacs-gowl-gabbrev--install-pickers ()
  "Register the `elisp' type, and register (or drop) the minibuffer pickers."
  (cmacs-gowl-gabbrev--register-elisp)
  (if cmacs-gowl-gabbrev-use-minibuffer
      (progn
        (cmacs-gowl-gabbrev-define-type "choice" #'cmacs-gowl-gabbrev--choice-type)
        (cmacs-gowl-gabbrev-define-type "form" #'cmacs-gowl-gabbrev--form-type)
        (cmacs-gowl-gabbrev-define-type "search" #'cmacs-gowl-gabbrev--search-type))
    (dolist (type '("choice" "form" "search"))
      (when (gethash type cmacs-gowl-gabbrev--types)
        (cmacs-gowl-gabbrev-undefine-type type)))))

;;;; abbrev-mode: the abbrev tables, everywhere

(defun cmacs-gowl-gabbrev--abbrev-hook-function (expansion hook)
  "A variable function giving EXPANSION after running abbrev HOOK on it.
The hook runs in a temporary buffer holding the expansion, point after
it -- where abbrev-mode would have left point -- and the buffer's text
afterwards is the replacement."
  (lambda (_ctx)
    (with-temp-buffer
      (insert expansion)
      (funcall hook)
      (buffer-string))))

(defun cmacs-gowl-gabbrev--abbrev-matches ()
  "The abbrevs of `cmacs-gowl-gabbrev-abbrev-tables', as match plists."
  (let (out)
    (dolist (name cmacs-gowl-gabbrev-abbrev-tables)
      (let ((table (and (boundp name) (symbol-value name))))
        (when (abbrev-table-p table)
          (let ((table-fixed (abbrev-table-get table :case-fixed)))
            (mapatoms
             (lambda (sym)
               (let ((abbrev (symbol-name sym))
                     (expansion (and (boundp sym) (symbol-value sym)))
                     (hook (symbol-function sym)))
                 (when (and (stringp expansion) (not (string-empty-p abbrev))
                            (or cmacs-gowl-gabbrev-abbrev-include-system
                                (not (abbrev-get sym :system))))
                   (let* ((trigger (concat cmacs-gowl-gabbrev-abbrev-prefix
                                           abbrev))
                          (fixed (or table-fixed (abbrev-get sym :case-fixed)))
                          (base (list :trigger trigger :word t
                                      :label (format "abbrev (%s)" name))))
                     (when (not fixed)
                       (setq base (append base (list :propagate-case t))))
                     (push
                      (if (functionp hook)
                          (let ((fname (format "abbrev:%s:%s" name abbrev)))
                            (cmacs-gowl-gabbrev-define-function
                             fname (cmacs-gowl-gabbrev--abbrev-hook-function
                                    expansion hook))
                            (append base
                                    (list :replace "{{value}}"
                                          :vars (list (list :name "value"
                                                            :type "elisp"
                                                            :params (list :function fname))))))
                        (append base (list :replace expansion)))
                      out)))))
             table)))))
    (nreverse out)))

(defvar cmacs-gowl-gabbrev--abbrev-timer nil
  "Pending re-export after an abbrev was defined.")

(defun cmacs-gowl-gabbrev--abbrev-changed (&rest _)
  "An abbrev changed: export the tables again, once things settle."
  (when (and cmacs-gowl-gabbrev-abbrev-tables (cmacs-gowl-gabbrev--running-p))
    (when (timerp cmacs-gowl-gabbrev--abbrev-timer)
      (cancel-timer cmacs-gowl-gabbrev--abbrev-timer))
    (setq cmacs-gowl-gabbrev--abbrev-timer
          (run-with-idle-timer 1 nil #'cmacs-gowl-gabbrev-sync-abbrevs))))

;;;###autoload
(defun cmacs-gowl-gabbrev-sync-abbrevs ()
  "Export `cmacs-gowl-gabbrev-abbrev-tables' to gabbrev now.
Runs by itself after `define-abbrev'; call it after editing tables in
ways that bypass that (`edit-abbrevs' does not)."
  (interactive)
  (when (cmacs-gowl-gabbrev--running-p)
    (let ((matches (cmacs-gowl-gabbrev--abbrev-matches)))
      (if matches
          (cmacs-gowl-gabbrev--command
           (concat "gabbrev-add --name abbrev "
                   (cmacs-gowl-gabbrev--encode (list :matches matches)))
           t)
        (cmacs-gowl-gabbrev--command "gabbrev-remove abbrev" t))
      (when (called-interactively-p 'interactive)
        (message "gabbrev: %d abbrev(s) exported" (length matches))))))

;;;; Pushing the configuration

(defun cmacs-gowl-gabbrev--deny ()
  "The deny filter to give the module."
  (let ((self (unless cmacs-gowl-gabbrev-in-emacs
                (format "pid = %d" (emacs-pid)))))
    (cond ((null cmacs-gowl-gabbrev-deny-filter)
           (if self (concat "+" self) nil))
          ((equal cmacs-gowl-gabbrev-deny-filter "none")
           (or self "none"))
          ((string-prefix-p "+" cmacs-gowl-gabbrev-deny-filter)
           (if self
               (format "%s or %s" cmacs-gowl-gabbrev-deny-filter self)
             cmacs-gowl-gabbrev-deny-filter))
          (self (format "(%s) or %s" cmacs-gowl-gabbrev-deny-filter self))
          (t cmacs-gowl-gabbrev-deny-filter))))

(defun cmacs-gowl-gabbrev--settings ()
  "The module settings, as the string alist `gowl-configure-module' takes."
  (let ((deny (cmacs-gowl-gabbrev--deny)))
    (append
     (list (cons "builtin" (if cmacs-gowl-gabbrev-builtin "true" "false"))
           (cons "start-on" (if cmacs-gowl-gabbrev-enable "true" "false")))
     (when deny (list (cons "deny-filter" deny)))
     cmacs-gowl-gabbrev-module-settings)))

(defun cmacs-gowl-gabbrev--espanso-dir ()
  "The espanso directory to load, or nil."
  (pcase cmacs-gowl-gabbrev-espanso
    ('nil nil)
    ('auto (let ((d (expand-file-name "espanso" (or (getenv "XDG_CONFIG_HOME")
                                                    "~/.config"))))
             (and (file-directory-p d) d)))
    ('t (expand-file-name "espanso" (or (getenv "XDG_CONFIG_HOME") "~/.config")))
    ((pred stringp) (expand-file-name cmacs-gowl-gabbrev-espanso))))

(defun cmacs-gowl-gabbrev--options-plist ()
  "`cmacs-gowl-gabbrev-options' and the option defcustoms, as one plist."
  (let (plist)
    (dolist (pair cmacs-gowl-gabbrev-options)
      (setq plist (append plist
                          (list (intern (concat ":" (cmacs-gowl-gabbrev--key
                                                     (car pair))))
                                (cdr pair)))))
    (when cmacs-gowl-gabbrev-toggle-key
      (setq plist (plist-put plist :toggle_key cmacs-gowl-gabbrev-toggle-key)))
    plist))

(defun cmacs-gowl-gabbrev--push-lisp ()
  "Give the module the Elisp source: options, AI rewrites, matches."
  (setq cmacs-gowl-gabbrev--push-timer nil)
  (when (cmacs-gowl-gabbrev--running-p)
    (let ((matches (append (cmacs-gowl-gabbrev--ai-matches)
                           cmacs-gowl-gabbrev-matches
                           (reverse cmacs-gowl-gabbrev--defined)))
          (options (cmacs-gowl-gabbrev--options-plist)))
      (cmacs-gowl-gabbrev--command
       (concat "gabbrev-add --name lisp "
               (cmacs-gowl-gabbrev--encode
                (append options (list :matches (or matches [])))))
       t))))

(defun cmacs-gowl-gabbrev--push-files ()
  "Give the module the files and the espanso directory, by name."
  (when (cmacs-gowl-gabbrev--running-p)
    (let ((espanso (cmacs-gowl-gabbrev--espanso-dir))
          (i 0))
      (if espanso
          (cmacs-gowl-gabbrev--command
           (concat "gabbrev-load --name espanso " espanso) t)
        (cmacs-gowl-gabbrev--command "gabbrev-remove espanso" t))
      (dolist (file cmacs-gowl-gabbrev-files)
        (cmacs-gowl-gabbrev--command
         (format "gabbrev-load --name file-%d %s" (cl-incf i)
                 (expand-file-name file))
         t)))))

(defun cmacs-gowl-gabbrev--uses-macros-p ()
  "Non-nil when a loaded match has a `macro' variable."
  (cl-some (lambda (m)
             (cl-some (lambda (v) (equal (alist-get 'type v) "macro"))
                      (alist-get 'vars m)))
           (ignore-errors (cmacs-gowl-gabbrev-list-matches))))

(defun cmacs-gowl-gabbrev--ensure-macros ()
  "Load gowl's macro module when a match calls a macro.
It is opt-in under cmacs (loaded on first use); a `macro' variable is a
use, and without the module it could only fail."
  (when (and (cmacs-gowl-gabbrev--uses-macros-p)
             (require 'cmacs-gowl-macro nil t))
    (condition-case err
        (cmacs-gowl-macro-ensure)
      (error (message "cmacs-gowl-gabbrev: cannot load the macro module: %s"
                      (error-message-string err))))))

;;;###autoload
(defun cmacs-gowl-gabbrev-apply ()
  "Push every `cmacs-gowl-gabbrev-*' setting into the running module."
  (interactive)
  (when (cmacs-gowl-gabbrev--running-p)
    (condition-case err
        (gowl-configure-module cmacs-gowl-gabbrev--module
                               (cmacs-gowl-gabbrev--settings))
      (error (message "cmacs-gowl-gabbrev: settings failed: %s"
                      (error-message-string err))))
    (cmacs-gowl-gabbrev--install-pickers)
    (cmacs-gowl-gabbrev--command "gabbrev-clear" t)
    (cmacs-gowl-gabbrev--push-files)
    (cmacs-gowl-gabbrev--push-lisp)
    (cmacs-gowl-gabbrev-sync-abbrevs)
    (cmacs-gowl-gabbrev--ensure-macros)
    (when (called-interactively-p 'interactive)
      (message "gabbrev: %s" (cmacs-gowl-gabbrev--summary)))))

;;;###autoload
(defun cmacs-gowl-gabbrev-start ()
  "Load gowl's `gabbrev' module if needed and give it this configuration.
Idempotent.  `cmacs --gowl' calls it at every compositor start."
  (interactive)
  (unless (cmacs-gowl-gabbrev--running-p)
    (user-error "Gowl compositor is not running"))
  (unless (gowl-run-command "gabbrev-status")
    (gowl-enable-module cmacs-gowl-gabbrev--module))
  (cmacs-gowl-gabbrev-apply)
  (cmacs-gowl-gabbrev--listen t)
  (cmacs-gowl-gabbrev--bind-keys))

(defun cmacs-gowl-gabbrev--bind-keys ()
  "Bind `cmacs-gowl-gabbrev-search-key' in gowl."
  (when (and cmacs-gowl-gabbrev-search-key (fboundp 'gowl-add-keybind))
    (condition-case err
        (gowl-add-keybind cmacs-gowl-gabbrev-search-key 'ipc-command
                          "gabbrev-search" "Expand what was typed (gabbrev)")
      (error (message "cmacs-gowl-gabbrev: cannot bind %s: %s"
                      cmacs-gowl-gabbrev-search-key
                      (error-message-string err))))))

;;;; Hearing the module

(defun cmacs-gowl-gabbrev--on-module-event (module text)
  "Handle the gabbrev module's announcement TEXT (MODULE is its name)."
  (when (equal module cmacs-gowl-gabbrev--module)
    (cond
     ((string-match "\\`rendered \\([^ ]+\\) \\(.*\\)\\'" text)
      (cmacs-gowl-gabbrev--rendered (match-string 1 text)
                                    (json-parse-string (match-string 2 text))))
     ((string-match "\\`render-failed \\([^ ]+\\) \\(.*\\)\\'" text)
      (cmacs-gowl-gabbrev--render-failed (match-string 1 text)
                                         (match-string 2 text)))
     ((string-match "\\`expanded \\(.*\\)\\'" text)
      (run-hook-with-args 'cmacs-gowl-gabbrev-expanded-functions
                          (match-string 1 text)))
     ((string-prefix-p "reloaded" text)
      (setq cmacs-gowl-gabbrev--triggers nil)))))

(defun cmacs-gowl-gabbrev--listen (on)
  "Hear the module's events when ON, else stop."
  (funcall (if on #'add-hook #'remove-hook)
           'cmacs-gowl-module-event-functions
           #'cmacs-gowl-gabbrev--on-module-event)
  (funcall (if on #'advice-add #'advice-remove)
           'define-abbrev :after #'cmacs-gowl-gabbrev--abbrev-changed))

(defvar cmacs-gowl-gabbrev--renders (make-hash-table :test #'equal)
  "Render id -> marker where an in-Emacs expansion goes.")

(defvar cmacs-gowl-gabbrev--next-render 0
  "Counter for render ids.")

(defun cmacs-gowl-gabbrev--rendered (id text)
  "A render ID finished with TEXT: insert it, or answer the search."
  (let ((ctx (gethash id cmacs-gowl-gabbrev--searches))
        (marker (gethash id cmacs-gowl-gabbrev--renders)))
    (remhash id cmacs-gowl-gabbrev--searches)
    (remhash id cmacs-gowl-gabbrev--renders)
    (cond
     (ctx (cmacs-gowl-gabbrev-answer ctx text))
     ((and marker (buffer-live-p (marker-buffer marker)))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (let ((inhibit-read-only nil))
            (insert text)))
        (when (= (point) marker)
          (goto-char (+ marker (length text))))
        (set-marker marker nil))))))

(defun cmacs-gowl-gabbrev--render-failed (id why)
  "A render ID failed, WHY."
  (let ((ctx (gethash id cmacs-gowl-gabbrev--searches))
        (marker (gethash id cmacs-gowl-gabbrev--renders)))
    (remhash id cmacs-gowl-gabbrev--searches)
    (remhash id cmacs-gowl-gabbrev--renders)
    (when ctx (cmacs-gowl-gabbrev-fail ctx why))
    (when marker (set-marker marker nil))
    (message "gabbrev: %s" (condition-case nil (json-parse-string why)
                             (error why)))))

(defun cmacs-gowl-gabbrev-render (match &optional marker)
  "Render MATCH (an id or trigger) and insert it at MARKER (default point).
The text arrives asynchronously: a match with a shell command or a
model in it takes as long as they take."
  (let ((id (format "emacs-%d" (cl-incf cmacs-gowl-gabbrev--next-render)))
        (m (or marker (copy-marker (point) t))))
    (puthash id m cmacs-gowl-gabbrev--renders)
    (condition-case err
        (cmacs-gowl-gabbrev--command (format "gabbrev-render --id %s %s" id match))
      (error (remhash id cmacs-gowl-gabbrev--renders)
             (signal (car err) (cdr err))))
    id))

;;;; Commands

(defun cmacs-gowl-gabbrev-status ()
  "The module's state, as an alist (`gabbrev-status').
Interactively, a summary in the echo area."
  (interactive)
  (let ((status (cmacs-gowl-gabbrev--json
                 (cmacs-gowl-gabbrev--command "gabbrev-status"))))
    (when (called-interactively-p 'interactive)
      (message "gabbrev: %s" (cmacs-gowl-gabbrev--summary status)))
    status))

(defun cmacs-gowl-gabbrev--summary (&optional status)
  "One line about STATUS (fetched when nil)."
  (let ((s (or status (cmacs-gowl-gabbrev--json
                       (or (cmacs-gowl-gabbrev--command "gabbrev-status" t)
                           "{}")))))
    (format "%s, %s match(es), %s expanded, %s failed%s"
            (if (alist-get 'on s) "on" "off")
            (alist-get 'matches s) (alist-get 'expanded s) (alist-get 'failed s)
            (let ((p (alist-get 'problems s)))
              (if p (format ", %d problem(s): %s" (length p) (car p)) "")))))

;;;###autoload
(defun cmacs-gowl-gabbrev-toggle (&optional arg)
  "Switch text expansion off or on.  With ARG, on if positive."
  (interactive "P")
  (let ((reply (cmacs-gowl-gabbrev--command
                (cond ((null arg) "gabbrev-toggle")
                      ((> (prefix-numeric-value arg) 0) "gabbrev-on")
                      (t "gabbrev-off")))))
    (message "Text expansion %s" reply)))

;;;###autoload
(defun cmacs-gowl-gabbrev-reload ()
  "Read every source again: files, espanso, your Elisp, the abbrevs."
  (interactive)
  (cmacs-gowl-gabbrev-apply)
  (message "gabbrev: %s" (cmacs-gowl-gabbrev--command "gabbrev-reload")))

(defun cmacs-gowl-gabbrev-list-matches (&optional filter)
  "Every match the module has (those whose id or label has FILTER)."
  (cmacs-gowl-gabbrev--json
   (cmacs-gowl-gabbrev--command
    (concat "gabbrev-list" (if filter (concat " " filter) "")))))

(defun cmacs-gowl-gabbrev--read-match (prompt)
  "Read a match id, with PROMPT, completing on triggers and labels."
  (let* ((rows (delq nil
                     (mapcar (lambda (m)
                               (let ((trig (car (alist-get 'triggers m))))
                                 (unless (alist-get 'overridden m)
                                   (cons (format "%-16s %s" (or trig (alist-get 'id m))
                                                 (or (alist-get 'label m)
                                                     (truncate-string-to-width
                                                      (or (alist-get 'replace m) "")
                                                      60)))
                                         (alist-get 'id m)))))
                             (cmacs-gowl-gabbrev-list-matches))))
         (pick (completing-read prompt rows nil t)))
    (cdr (assoc pick rows))))

;;;###autoload
(defun cmacs-gowl-gabbrev-insert (match)
  "Insert MATCH's expansion at point in this buffer.
Interactively, pick it by trigger or label."
  (interactive (list (cmacs-gowl-gabbrev--read-match "Insert snippet: ")))
  (barf-if-buffer-read-only)
  (cmacs-gowl-gabbrev-render match))

;;;###autoload
(defun cmacs-gowl-gabbrev-search ()
  "Pick a match and type it into the window that has focus.
This is what `cmacs-gowl-gabbrev-search-key' runs; from inside Emacs,
`cmacs-gowl-gabbrev-insert' is the one that inserts here."
  (interactive)
  (cmacs-gowl-gabbrev--command "gabbrev-search"))

;;;###autoload
(defun cmacs-gowl-gabbrev-test (text)
  "Say which match TEXT, typed into the focused window, would fire."
  (interactive "sType: ")
  (let ((r (cmacs-gowl-gabbrev--json
            (cmacs-gowl-gabbrev--command (concat "gabbrev-test " text)))))
    (message "%s"
             (cond ((alist-get 'denied r) "That window is on the deny list")
                   ((alist-get 'disabled r)
                    (format "Expansion is off in that window (profile %s)"
                            (alist-get 'profile r)))
                   ((alist-get 'match r)
                    (format "`%s' fires %s (profile %s)" (alist-get 'typed r)
                            (alist-get 'match r)
                            (or (alist-get 'profile r) "default")))
                   (t "Nothing fires")))
    r))

;;;; The list buffer

(defvar cmacs-gowl-gabbrev-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-gowl-gabbrev-list-insert)
    (define-key map (kbd "g") #'cmacs-gowl-gabbrev-list)
    (define-key map (kbd "r") #'cmacs-gowl-gabbrev-reload)
    (define-key map (kbd "t") #'cmacs-gowl-gabbrev-toggle)
    map)
  "Keys of `cmacs-gowl-gabbrev-list-mode'.")

(define-derived-mode cmacs-gowl-gabbrev-list-mode tabulated-list-mode "gabbrev"
  "Every gabbrev match: trigger, what it does, where it comes from.
\\<cmacs-gowl-gabbrev-list-mode-map>
\\[cmacs-gowl-gabbrev-list-insert] inserts one in the buffer you came from,
\\[cmacs-gowl-gabbrev-reload] reloads, and
\\[cmacs-gowl-gabbrev-toggle] switches expansion off and on."
  (setq tabulated-list-format [("Trigger" 18 t) ("Does" 56 nil) ("From" 30 t)])
  (setq tabulated-list-sort-key '("Trigger" . nil))
  (tabulated-list-init-header))

(defvar-local cmacs-gowl-gabbrev--list-origin nil
  "The buffer the list was opened from.")

;;;###autoload
(defun cmacs-gowl-gabbrev-list ()
  "List every gabbrev match."
  (interactive)
  (let ((origin (if (derived-mode-p 'cmacs-gowl-gabbrev-list-mode)
                    cmacs-gowl-gabbrev--list-origin
                  (current-buffer)))
        (matches (cmacs-gowl-gabbrev-list-matches)))
    (with-current-buffer (get-buffer-create "*gabbrev*")
      (cmacs-gowl-gabbrev-list-mode)
      (setq cmacs-gowl-gabbrev--list-origin origin)
      (setq tabulated-list-entries
            (mapcar (lambda (m)
                      (let ((does (or (alist-get 'label m)
                                      (replace-regexp-in-string
                                       "\n" "⏎" (or (alist-get 'replace m) "")))))
                        (list (alist-get 'id m)
                              (vector (propertize
                                       (or (car (alist-get 'triggers m))
                                           (alist-get 'regex m) "")
                                       'face (if (alist-get 'overridden m)
                                                 'shadow 'default))
                                      does
                                      (abbreviate-file-name
                                       (or (alist-get 'source m) ""))))))
                    matches))
      (tabulated-list-print)
      (pop-to-buffer (current-buffer)))))

(defun cmacs-gowl-gabbrev-list-insert ()
  "Insert the match at point in the buffer the list came from."
  (interactive)
  (let ((id (tabulated-list-get-id))
        (origin cmacs-gowl-gabbrev--list-origin))
    (unless (buffer-live-p origin)
      (user-error "The buffer this list came from is gone"))
    (pop-to-buffer origin)
    (cmacs-gowl-gabbrev-insert id)))

;;;; Inside Emacs: gabbrev's triggers in buffers

(defun cmacs-gowl-gabbrev--trigger-table ()
  "The literal triggers, longest first, fetched once per reload."
  (or cmacs-gowl-gabbrev--triggers
      (setq cmacs-gowl-gabbrev--triggers
            (sort
             (cl-loop for m in (ignore-errors (cmacs-gowl-gabbrev-list-matches))
                      unless (or (alist-get 'search-only m)
                                 (alist-get 'overridden m))
                      append (cl-loop for trig in (alist-get 'triggers m)
                                      collect (list trig (alist-get 'id m)
                                                    (alist-get 'word m)
                                                    (alist-get 'word m))))
             (lambda (a b) (> (length (car a)) (length (car b))))))))

(defun cmacs-gowl-gabbrev--separator-p (char)
  "Non-nil when CHAR separates words (espanso's default set)."
  (and char (memq char '(?\s ?, ?. ?? ?! ?\r ?\n ?\t ?' ?\" ?\f ?\( ?\) ?\[ ?\]
                          ?{ ?} ?< ?> ?: ?\; ? ))))

(defun cmacs-gowl-gabbrev--after-insert ()
  "`post-self-insert-hook': expand a gabbrev trigger that just completed."
  (when (and cmacs-gowl-gabbrev-emacs-mode (not buffer-read-only)
             (cmacs-gowl-gabbrev--running-p))
    (let* ((char (char-before))
           (sep (cmacs-gowl-gabbrev--separator-p char)))
      (cl-loop
       for (trig id left right) in (cmacs-gowl-gabbrev--trigger-table)
       for end = (if right (and sep (1- (point))) (point))
       for start = (and end (- end (length trig)))
       when (and end (>= start (point-min))
                 (string= (buffer-substring-no-properties start end) trig)
                 (or (not left) (= start (point-min))
                     (cmacs-gowl-gabbrev--separator-p (char-before start))))
       return (progn
                (delete-region start end)
                (cmacs-gowl-gabbrev-render id (copy-marker start)))))))

;;;###autoload
(define-minor-mode cmacs-gowl-gabbrev-emacs-mode
  "Expand gabbrev's triggers in Emacs buffers, as you type.
The same matches, variables and renderer as every other window -- so
;today gives the date here too -- but as buffer edits (one undo
step), not keys.  The text arrives asynchronously when a match runs a
command or a model."
  :global t
  :group 'cmacs-gowl-gabbrev
  (if cmacs-gowl-gabbrev-emacs-mode
      (add-hook 'post-self-insert-hook #'cmacs-gowl-gabbrev--after-insert)
    (remove-hook 'post-self-insert-hook #'cmacs-gowl-gabbrev--after-insert)))

;;;; Startup

(defun cmacs-gowl-gabbrev--on-start ()
  "Configure the module cmacs loaded, and start listening.
Called by `cmacs-gowl-mode' when the compositor (re)starts.  The module
is in cmacs's default set (cmacs-gowl.c); a build without it is
reported and otherwise ignored."
  (setq cmacs-gowl-gabbrev--triggers nil)
  (condition-case err
      (cmacs-gowl-gabbrev-start)
    (error (message "cmacs-gowl-gabbrev: %s" (error-message-string err)))))

(provide 'cmacs-gowl-gabbrev)

;;; cmacs-gowl-gabbrev.el ends here
