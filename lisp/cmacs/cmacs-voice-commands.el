;;; cmacs-voice-commands.el --- Voice commands: Emacs, the desktop, macros, tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of cmacs, a fork of GNU Emacs.

;;; Commentary:

;; Spoken commands that act directly, without a chat model in between:
;;
;;   "workspace three"          "move this to workspace two"
;;   "focus firefox"            "focus left"
;;   "close window"             (asks first: destructive)
;;   "tile left" / "monocle"    "layout scrolling"
;;   "run standup"              a gowl macro, or a brigade tool, by name
;;   "use tool web search for emacs news"
;;   "fire event backup now"    a podomation event
;;   "run rule standup"         runs podomation pod standup's rules
;;   "save", "undo", "other window", "org agenda" ...
;;
;; The registry, `cmacs-voice-commands', is the VR voice-command
;; registry generalised: entries are (REGEXP FUNCTION DOC PROPS), tried
;; in order against the normalised text; PROPS may restrict an entry to
;; a `:context' (`vr' or `desktop') or a `:when' predicate (the gowl
;; entries need a running compositor), and mark it `:destructive'.
;; Anything matching no entry is tried as an Emacs command name ("org
;; agenda" -> `org-agenda').
;;
;; Names are matched exactly first, then fuzzily
;; (`cmacs-voice-command-threshold'), against what is registered right
;; now: `cmacs-gowl-macro-list', `cmacs-brigade-registry-list',
;; `gowl-list-clients', `gowl-list-layouts'.
;;
;; Destructive actions -- closing a window, a brigade tool marked
;; `:destructive', a macro in `cmacs-voice-destructive-macros' -- are
;; confirmed first (`cmacs-voice-confirm-destructive'): the question is
;; shown and spoken, and answered by saying "yes"/"no" (the next
;; utterance, to the loop or a push-to-talk) or pressing y/n.  Nothing
;; blocks while it waits.
;;
;; Every compositor call is one of gowl's own DEFUNs, called from the
;; main thread; those take the gowl lock themselves.  Nothing here runs
;; Lisp anywhere else.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-voice)

(declare-function gowl-running-p "cmacs-gowl-defuns.c")
(declare-function gowl-view-tags "cmacs-gowl-defuns.c" (tagmask &optional monitor))
(declare-function gowl-set-tags "cmacs-gowl-defuns.c" (client tags))
(declare-function gowl-set-layout "cmacs-gowl-defuns.c" (layout &optional monitor))
(declare-function gowl-list-layouts "cmacs-gowl-defuns.c")
(declare-function gowl-list-clients "cmacs-gowl-defuns.c")
(declare-function gowl-client-info "cmacs-gowl-defuns.c" (client))
(declare-function gowl-focused-client "cmacs-gowl-defuns.c")
(declare-function gowl-focus-client "cmacs-gowl-defuns.c" (client))
(declare-function gowl-focus-direction "cmacs-gowl-defuns.c" (direction))
(declare-function gowl-close-client "cmacs-gowl-defuns.c" (client))
(declare-function gowl-toggle-client-floating "cmacs-gowl-defuns.c" (client))
(declare-function gowl-toggle-client-fullscreen "cmacs-gowl-defuns.c" (client))
(declare-function cmacs-gowl-macro-run "cmacs-gowl-macro" (name &rest args))
(declare-function cmacs-gowl-macro-list "cmacs-gowl-macro")
(declare-function cmacs-podomation-emit-event "cmacs-podomation.c" (event data))
(declare-function cmacs-podomation-run-pod "cmacs-podomation.c" (name &optional event data))
(declare-function cmacs-podomation-list-pods "cmacs-podomation.c")
(declare-function cmacs-podomation-running-p "cmacs-podomation.c")
(declare-function cmacs-brigade-registry-list "cmacs-brigade-registry" (kind))
(declare-function cmacs-brigade-registry-get "cmacs-brigade-registry" (kind name))
(declare-function cmacs-brigade-call-tool "cmacs-brigade-tools"
                  (wire json &optional agent allowlist task))
(declare-function cmacs-brigade-tool-wire-name "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-params "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-destructive "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-description "cmacs-brigade-registry" (tool))
(declare-function cmacs-lrg-vr-active-now-p "cmacs-lrg-vr")
(declare-function cmacs-voice-loop--arm "cmacs-voice-loop" (seconds))
(defvar cmacs-voice-loop-mode)


;;;; Customization

(defgroup cmacs-voice-commands nil
  "Spoken commands that act without a chat model."
  :group 'cmacs-voice
  :prefix "cmacs-voice-")

(defcustom cmacs-voice-confirm-destructive t
  "Whether destructive voice actions are confirmed first.
t asks, and takes a spoken \"yes\"/\"no\" or a y/n key; `keyboard'
asks and takes only y/n; nil acts at once."
  :type '(choice (const :tag "Ask (voice or keyboard)" t)
                 (const :tag "Ask (keyboard only)" keyboard)
                 (const :tag "Never ask" nil)))

(defcustom cmacs-voice-confirm-seconds 15
  "Seconds a confirmation waits for an answer before it is dropped."
  :type 'number)

(defcustom cmacs-voice-command-threshold 0.7
  "Similarity (0..1) a spoken name needs to match a registered one fuzzily."
  :type 'number)

(defcustom cmacs-voice-destructive-macros nil
  "Names of gowl macros that are confirmed before a voice command runs them."
  :type '(repeat string))

(defcustom cmacs-voice-commands-unmatched 'message
  "What a voice command that matches nothing does outside VR.
`message' says it was not understood; `minibuffer' opens M-x with the
words typed in.  (VR uses `cmacs-lrg-vr-voice-unmatched'.)"
  :type '(choice (const message) (const minibuffer)))

(defcustom cmacs-voice-commands-speak-feedback nil
  "Non-nil: say what a voice command did, as well as showing it."
  :type 'boolean)

(defvar cmacs-voice-command-functions nil
  "Abnormal hook run with (TEXT FUNCTION) after a voice command runs.")


;;;; The registry

(defvar cmacs-voice-commands nil
  "Voice commands: a list of (REGEXP FUNCTION DOC PROPS), tried in order.
The spoken text is lower-cased, its punctuation removed and number
words after \"workspace\", \"line\", \"number\" or \"tab\" turned into
digits before it is matched against each REGEXP, whole.  FUNCTION is
called with the regexp's groups as string arguments (nil for a group
that did not match), from the command loop.  DOC is shown by
\\[cmacs-voice-commands-help].  PROPS is a plist:
  :context SYM     only in that context: `vr' (the VR session) or
                   `desktop' (everywhere else); nil means both
  :when FN         only when (FN) returns non-nil
  :destructive B   confirm first (see `cmacs-voice-confirm-destructive');
                   B may be a function of the groups returning non-nil
                   when this particular call is destructive
Add your own with `cmacs-voice-define-command'.")

(defun cmacs-voice-define-command (regexp function &optional doc append &rest props)
  "Add a voice command: speech matching REGEXP calls FUNCTION.
FUNCTION gets REGEXP's groups as arguments.  New commands are tried
before the shipped ones unless APPEND.  DOC is a short description
\(\"workspace N\").  PROPS: see `cmacs-voice-commands'.  A REGEXP
already defined in the same context is replaced."
  (setq cmacs-voice-commands
        (cl-remove-if (lambda (e) (and (equal (car e) regexp)
                                       (eq (plist-get (nth 3 e) :context)
                                           (plist-get props :context))))
                      cmacs-voice-commands))
  (let ((entry (list regexp function doc props)))
    (setq cmacs-voice-commands
          (if append
              (append cmacs-voice-commands (list entry))
            (cons entry cmacs-voice-commands))))
  regexp)

(defconst cmacs-voice-command-numbers
  '(("zero" . 0) ("one" . 1) ("won" . 1) ("two" . 2) ("to" . 2) ("too" . 2)
    ("three" . 3) ("four" . 4) ("for" . 4) ("five" . 5) ("six" . 6)
    ("seven" . 7) ("eight" . 8) ("nine" . 9) ("ten" . 10) ("eleven" . 11)
    ("twelve" . 12) ("first" . 1) ("second" . 2) ("third" . 3)
    ("fourth" . 4) ("fifth" . 5))
  "Spoken numbers and their values, for workspace and line numbers.")

(defun cmacs-voice-command-normalize (text)
  "TEXT lower-cased, without punctuation, with number words as digits.
Number words become digits only after \"workspace\", \"line\",
\"number\" or \"tab\", where a number is expected: \"open two files\"
stays put."
  (let* ((s (downcase (or text "")))
         (s (replace-regexp-in-string "[^[:alnum:] '._/-]" " " s))
         (s (replace-regexp-in-string "\\.\\'\\|\\. " " " s))
         (s (string-trim (replace-regexp-in-string "[ \t]+" " " s))))
    (replace-regexp-in-string
     "\\(\\(?:workspace\\|line\\|number\\|tab\\) \\)\\([a-z]+\\)\\b"
     (lambda (m)
       (let ((n (assoc (match-string 2 m) cmacs-voice-command-numbers)))
         (if n
             (concat (match-string 1 m) (number-to-string (cdr n)))
           m)))
     s t t)))

(defun cmacs-voice-command-context ()
  "The context voice commands run in now: `vr' or `desktop'."
  (if (and (fboundp 'cmacs-lrg-vr-active-now-p) (cmacs-lrg-vr-active-now-p))
      'vr 'desktop))

(defun cmacs-voice--say (fmt &rest args)
  "Show FMT with ARGS; speak it too when feedback is on.  Returns the text."
  (let ((msg (apply #'format fmt args)))
    (message "%s" msg)
    (when cmacs-voice-commands-speak-feedback
      (ignore-errors (cmacs-voice-speak msg)))
    msg))

(defun cmacs-voice--command-name (words)
  "The Emacs command WORDS name (\"org agenda\" -> `org-agenda'), or nil."
  (let ((sym (intern-soft (replace-regexp-in-string " " "-" words))))
    (and sym (commandp sym) sym)))


;;;; Confirmation

(defvar cmacs-voice--confirm nil
  "The pending confirmation: (PROMPT ACTION DEADLINE), or nil.")

(defun cmacs-voice-confirm-pending-p ()
  "Non-nil while a destructive voice action waits for a yes or no."
  (and cmacs-voice--confirm
       (if (< (float-time) (nth 2 cmacs-voice--confirm)) t
         (setq cmacs-voice--confirm nil))))

(defun cmacs-voice--confirm-resolve (yes)
  "Answer the pending confirmation: run its action when YES."
  (when-let* ((c cmacs-voice--confirm))
    (setq cmacs-voice--confirm nil)
    (if yes
        (progn (message "Voice: %s -- yes" (car c))
               (cmacs-voice-run-later (nth 1 c)))
      (cmacs-voice--say "Cancelled."))))

(defun cmacs-voice-confirm-answer (text)
  "Treat TEXT as the answer to a pending confirmation.
Returns non-nil when TEXT was an answer (and was acted on)."
  (when (and (cmacs-voice-confirm-pending-p)
             (not (eq cmacs-voice-confirm-destructive 'keyboard)))
    (let ((s (cmacs-voice-command-normalize text)))
      (cond
       ((string-match-p "\\`\\(?:yes\\|yeah\\|yep\\|do it\\|confirm\\|go ahead\\|sure\\|ok\\|okay\\)\\b" s)
        (cmacs-voice--confirm-resolve t) t)
       ((string-match-p "\\`\\(?:no\\|nope\\|cancel\\|stop\\|don't\\|never ?mind\\|abort\\)\\b" s)
        (cmacs-voice--confirm-resolve nil) t)))))

(defun cmacs-voice-confirm (prompt action)
  "Run ACTION (a function of no arguments) once PROMPT is answered yes.
Under `cmacs-voice-confirm-destructive' nil, ACTION runs at once.
Otherwise PROMPT is shown and spoken and the answer is the next spoken
yes/no (see `cmacs-voice-confirm-answer') or a y/n key; nothing blocks
while it waits, and it lapses after `cmacs-voice-confirm-seconds'."
  (if (not cmacs-voice-confirm-destructive)
      (cmacs-voice-run-later action)
    (setq cmacs-voice--confirm
          (list prompt action (+ (float-time) cmacs-voice-confirm-seconds)))
    (let ((m (make-sparse-keymap)))
      (define-key m "y" (lambda () (interactive) (cmacs-voice--confirm-resolve t)))
      (define-key m "n" (lambda () (interactive) (cmacs-voice--confirm-resolve nil)))
      (unless noninteractive
        (set-transient-map m (lambda () (cmacs-voice-confirm-pending-p)))))
    (message "%s (y/n%s)" prompt
             (if (eq cmacs-voice-confirm-destructive 'keyboard) "" ", or say yes/no"))
    (unless (eq cmacs-voice-confirm-destructive 'keyboard)
      (ignore-errors (cmacs-voice-speak prompt))
      ;; With the loop on, the answer needs no wake phrase.
      (when (and (bound-and-true-p cmacs-voice-loop-mode)
                 (fboundp 'cmacs-voice-loop--arm))
        (cmacs-voice-loop--arm cmacs-voice-confirm-seconds)))
    'pending))


;;;; Running a spoken command

(defun cmacs-voice--entry-applies-p (entry context)
  "Non-nil when registry ENTRY may run in CONTEXT."
  (let* ((props (nth 3 entry))
         (ctx (plist-get props :context))
         (pred (plist-get props :when)))
    (and (or (null ctx) (eq ctx context))
         (or (null pred) (ignore-errors (funcall pred))))))

(cl-defun cmacs-voice-command-run (text &key context unmatched)
  "Do what the spoken TEXT says; return the function run, or nil.
TEXT is first an answer to a pending confirmation, then tried against
`cmacs-voice-commands' (entries for CONTEXT, default
`cmacs-voice-command-context'), then as an Emacs command name.
UNMATCHED, default `cmacs-voice-commands-unmatched', says what happens
to anything else.  A destructive action asks first and returns
`pending'; an answer to a pending question returns `confirm'."
  (if (cmacs-voice-confirm-answer text)
      'confirm
    (let ((s (cmacs-voice-command-normalize text))
          (context (or context (cmacs-voice-command-context)))
          (case-fold-search t))
      (catch 'done
        (dolist (entry cmacs-voice-commands)
          (pcase-let ((`(,re ,fn ,doc ,props) entry))
            (when (and (string-match (concat "\\`\\(?:" re "\\)\\'") s)
                       (cmacs-voice--entry-applies-p entry context))
              (let* ((args (cl-loop for i from 1 to (regexp-opt-depth re)
                                    collect (match-string i s)))
                     (d (plist-get props :destructive))
                     (destructive (if (functionp d) (apply d args) d))
                     (action (lambda ()
                               (apply fn args)
                               (run-hook-with-args 'cmacs-voice-command-functions
                                                   text fn))))
                (if destructive
                    (throw 'done
                           (cmacs-voice-confirm
                            (format "%s?" (if (stringp destructive) destructive
                                            (capitalize (or doc s))))
                            action))
                  (message "\"%s\"" text)
                  (funcall action)
                  ;; The function may have asked for confirmation itself
                  ;; (a destructive tool or macro, found by name).
                  (throw 'done (if (cmacs-voice-confirm-pending-p) 'pending fn)))))))
        (let ((cmd (cmacs-voice--command-name s)))
          (when cmd
            (cmacs-voice--say "\"%s\" -> %s" text cmd)
            (setq this-command cmd)
            (call-interactively cmd)
            (throw 'done cmd)))
        (if (eq (or unmatched cmacs-voice-commands-unmatched) 'minibuffer)
            (progn
              (cmacs-voice--say "\"%s\" -- pick a command" text)
              (minibuffer-with-setup-hook
                  (lambda () (insert (replace-regexp-in-string " " "-" s)))
                (call-interactively #'execute-extended-command)))
          (cmacs-voice--say "Didn't understand \"%s\"" text))
        nil))))

;;;###autoload
(defun cmacs-voice-command ()
  "Say a voice command: run once to start listening, again to do it.
Push-to-talk through the shared engine (the always-on loop, if on,
pauses meanwhile).  What was said runs through
`cmacs-voice-command-run' -- desktop, macros, tools, Emacs commands --
and never reaches a chat model.  Also stops on its own after 15 s."
  (interactive)
  (if (cmacs-voice-ptt-active-p 'command)
      (let ((pcm (cmacs-voice-ptt-stop 'command)))
        (if (< (length pcm) 8000)
            (progn (fillarray pcm 0)
                   (message "Voice: too short"))
          (message "Voice: transcribing...")
          (cmacs-voice-transcribe
           pcm
           (lambda (r)
             (let ((err (cdr (assq :error r)))
                   (text (cmacs-voice-clean (cdr (assq :text r)))))
               (cond (err (message "Voice: %s" err))
                     ((string-empty-p text) (message "Voice: heard nothing"))
                     (t (cmacs-voice-run-later
                         (lambda () (cmacs-voice-command-run text))))))))))
    (unless (cmacs-voice-available-p)
      (user-error "Voice commands need audio and whisper in this build"))
    (cmacs-voice-ptt-start 'command :max-seconds 15
                           :on-timeout #'cmacs-voice-command)
    (message "Listening -- say a command (%s again to finish)..."
             (substitute-command-keys "\\[cmacs-voice-command]"))))

;;;###autoload (define-key cmacs-voice-map (kbd "v") #'cmacs-voice-command)
;;;###autoload (define-key cmacs-voice-map (kbd "?") #'cmacs-voice-commands-help)

;;;###autoload
(defun cmacs-voice-commands-help ()
  "List the voice commands that apply here."
  (interactive)
  (let ((ctx (cmacs-voice-command-context)))
    (with-help-window "*Voice Commands*"
      (princ (format "Voice commands (%s):\n\n" ctx))
      (dolist (e cmacs-voice-commands)
        (when (cmacs-voice--entry-applies-p e ctx)
          (princ (format "  %-40s %s%s\n" (or (nth 2 e) "") (nth 1 e)
                         (if (plist-get (nth 3 e) :destructive) "  (asks)" "")))))
      (princ "\nAnything else is tried as a command name (\"org agenda\").\n")
      (princ "Destructive commands ask first: say yes or no, or press y/n.\n"))))


;;;; Names: what is registered right now, matched exactly then fuzzily

(defun cmacs-voice-best-name (spoken candidates &optional threshold)
  "The member of CANDIDATES (strings) SPOKEN best names, or nil.
Comparison is on lower-cased words with separators (-, _, .) as
spaces: an exact match wins, then a candidate containing all the
spoken words, then the most similar above THRESHOLD (default
`cmacs-voice-command-threshold')."
  (let* ((norm (lambda (s) (string-trim
                            (replace-regexp-in-string
                             "[-_./ ]+" " "
                             (downcase (file-name-sans-extension (or s "")))))))
         (want (funcall norm spoken))
         (words (split-string want))
         (threshold (or threshold cmacs-voice-command-threshold))
         (best nil) (best-score 0.0))
    (unless (string-empty-p want)
      (or (cl-find want candidates :key norm :test #'string=)
          (cl-find-if (lambda (c) (let ((cn (funcall norm c)))
                                    (cl-every (lambda (w) (string-search w cn)) words)))
                      candidates)
          (progn
            (dolist (c candidates)
              (let ((score (cmacs-voice-similarity want (funcall norm c))))
                (when (> score best-score) (setq best c best-score score))))
            (and (>= best-score threshold) best))))))

(defun cmacs-voice--gowl-p ()
  "Non-nil when a gowl compositor is running in this Emacs."
  (and (fboundp 'gowl-running-p) (ignore-errors (gowl-running-p))))

(defun cmacs-voice--macro-names ()
  "Names of the gowl macros runnable now."
  (when (or (fboundp 'cmacs-gowl-macro-list) (require 'cmacs-gowl-macro nil t))
    (delq nil (mapcar (lambda (m) (alist-get 'name m))
                      (ignore-errors (cmacs-gowl-macro-list))))))

(defun cmacs-voice--tool-names ()
  "Names of the brigade tools, as strings."
  (when (fboundp 'cmacs-brigade-registry-list)
    (mapcar #'symbol-name (ignore-errors (cmacs-brigade-registry-list 'tool)))))

(defun cmacs-voice--clients ()
  "Each gowl window as (LABEL . CLIENT), labelled \"app-id title\"."
  (when (fboundp 'gowl-list-clients)
    (mapcar (lambda (c)
              (let ((info (ignore-errors (gowl-client-info c))))
                (cons (string-trim (format "%s %s"
                                           (or (alist-get 'app-id info) "")
                                           (or (alist-get 'title info) "")))
                      c)))
            (ignore-errors (gowl-list-clients)))))


;;;; Desktop actions (gowl)

(defun cmacs-voice-workspace (n)
  "Show workspace (tag) N, a number or numeric string."
  (let ((n (if (stringp n) (string-to-number n) n)))
    (unless (and (integerp n) (<= 1 n 31))
      (user-error "No workspace %s" n))
    (gowl-view-tags (ash 1 (1- n)))
    (cmacs-voice--say "Workspace %d" n)))

(defun cmacs-voice-move-to-workspace (n)
  "Move the focused window to workspace (tag) N."
  (let ((n (if (stringp n) (string-to-number n) n))
        (c (gowl-focused-client)))
    (unless c (user-error "No window is focused"))
    (unless (and (integerp n) (<= 1 n 31)) (user-error "No workspace %s" n))
    (gowl-set-tags c (ash 1 (1- n)))
    (cmacs-voice--say "Moved to workspace %d" n)))

(defun cmacs-voice-focus-window (name)
  "Focus the window whose app id or title best matches spoken NAME."
  (let* ((clients (cmacs-voice--clients))
         (hit (cmacs-voice-best-name name (mapcar #'car clients))))
    (if (not hit)
        (cmacs-voice--say "No window like \"%s\"" name)
      (gowl-focus-client (cdr (assoc hit clients)))
      (cmacs-voice--say "Focused %s" hit))))

(defun cmacs-voice-focus-direction (dir)
  "Focus the nearest window in spoken direction DIR."
  (gowl-focus-direction (intern dir)))

(defun cmacs-voice--close-target (name)
  "The client NAME refers to (nil: the focused one), and its label."
  (if (or (null name) (member name '("this" "this window" "window" "it")))
      (let ((c (gowl-focused-client)))
        (cons c (and c (or (alist-get 'title (ignore-errors (gowl-client-info c)))
                           "this window"))))
    (let* ((clients (cmacs-voice--clients))
           (hit (cmacs-voice-best-name name (mapcar #'car clients))))
      (cons (and hit (cdr (assoc hit clients))) hit))))

(defun cmacs-voice-close-window (&optional name)
  "Close the window spoken NAME refers to, or the focused one."
  (pcase-let ((`(,c . ,label) (cmacs-voice--close-target name)))
    (if (not c)
        (cmacs-voice--say "No window to close")
      (gowl-close-client c)
      (cmacs-voice--say "Closed %s" label))))

(defconst cmacs-voice-layout-words
  '(("tile left" . "tile") ("tile" . "tile") ("tiling" . "tile") ("tiled" . "tile")
    ("monocle" . "monocle") ("fullscreen layout" . "monocle")
    ("tabbed" . "tabbed") ("tabs" . "tabbed")
    ("float" . "float") ("floating" . "float")
    ("scrolling" . "scrolling") ("scroll" . "scrolling"))
  "Spoken layout names and the gowl layouts they mean.
\"tile left\" is dwm's tile -- master on the left, stack on the right.")

(defun cmacs-voice-set-layout (spoken)
  "Switch the focused monitor to the layout SPOKEN names."
  (let* ((s (string-trim (replace-regexp-in-string "\\blayout\\b" "" spoken)))
         (known (ignore-errors (gowl-list-layouts)))
         (name (or (cdr (assoc s cmacs-voice-layout-words))
                   (cmacs-voice-best-name s known))))
    (if (and name (gowl-set-layout name))
        (cmacs-voice--say "Layout %s" name)
      (cmacs-voice--say "No layout \"%s\"" s))))


;;;; Macros, tools, podomation

(defun cmacs-voice-run-macro (name)
  "Run the gowl macro spoken NAME best matches."
  (let ((hit (cmacs-voice-best-name name (cmacs-voice--macro-names))))
    (if (not hit)
        (cmacs-voice--say "No macro \"%s\"" name)
      (cmacs-voice--say "Macro %s: %s" hit (cmacs-gowl-macro-run hit)))))

(defun cmacs-voice--tool (name)
  "The brigade tool object for NAME (a string), or nil."
  (and (fboundp 'cmacs-brigade-registry-get)
       (cmacs-brigade-registry-get 'tool (intern name))))

(defun cmacs-voice--tool-json (tool arg)
  "JSON arguments for TOOL given spoken ARG, or :needs-args."
  (let ((params (cmacs-brigade-tool-params tool))
        (key (lambda (p) (intern (format "%s" (plist-get p :name))))))
    (cond
     ((null params) "{}")
     ((and arg (= (length params) 1))
      (json-serialize (list (cons (funcall key (car params)) arg))))
     ((and arg (cl-every (lambda (p) (not (plist-get p :required))) (cdr params)))
      (json-serialize (list (cons (funcall key (car params)) arg))))
     ((cl-notany (lambda (p) (plist-get p :required)) params) "{}")
     (t :needs-args))))

(defun cmacs-voice-run-tool (name &optional arg)
  "Call the brigade tool spoken NAME best matches, with spoken ARG.
A tool with no parameters runs as is; one whose only required parameter
is a string gets ARG.  Tools marked destructive are confirmed first; a
tool's own `:confirm' is still asked by the brigade."
  (let* ((hit (cmacs-voice-best-name name (cmacs-voice--tool-names)))
         (tool (and hit (cmacs-voice--tool hit))))
    (if (not tool)
        (cmacs-voice--say "No tool \"%s\"" name)
      (let ((json (cmacs-voice--tool-json tool arg))
            (wire (cmacs-brigade-tool-wire-name tool)))
        (if (eq json :needs-args)
            (cmacs-voice--say "%s needs arguments I can't take by voice" hit)
          (let ((action (lambda ()
                          (cmacs-voice--say "%s: %s" hit
                                            (truncate-string-to-width
                                             (format "%s" (cmacs-brigade-call-tool
                                                           wire json "voice"))
                                             200 nil nil "...")))))
            (if (cmacs-brigade-tool-destructive tool)
                (cmacs-voice-confirm (format "Run %s?" hit) action)
              (funcall action))))))))

(defun cmacs-voice-run-named (name)
  "Run what spoken NAME names: a gowl macro, else a brigade tool.
\"run standup\" runs a macro called standup if there is one."
  (let ((macro (cmacs-voice-best-name name (cmacs-voice--macro-names)))
        (tool (cmacs-voice-best-name name (cmacs-voice--tool-names))))
    (cond
     ((and macro (member macro cmacs-voice-destructive-macros))
      (cmacs-voice-confirm (format "Run macro %s?" macro)
                           (lambda () (cmacs-voice-run-macro macro))))
     (macro (cmacs-voice-run-macro macro))
     (tool (cmacs-voice-run-tool tool))
     ((cmacs-voice--command-name name)
      (call-interactively (cmacs-voice--command-name name)))
     (t (cmacs-voice--say "Nothing called \"%s\"" name)))))

(defun cmacs-voice-emit-event (name)
  "Emit podomation event NAME (spoken words joined by underscores)."
  (let ((event (replace-regexp-in-string "[ -]+" "_" (string-trim name))))
    (cmacs-podomation-emit-event event (list (cons "source" "voice")))
    (cmacs-voice--say "Event %s" event)))

(defun cmacs-voice--pod-names ()
  "Names of the podomation pods, when the engine runs."
  (when (and (fboundp 'cmacs-podomation-list-pods)
             (ignore-errors (cmacs-podomation-running-p)))
    (mapcar (lambda (p) (format "%s" (car p)))
            (ignore-errors (cmacs-podomation-list-pods)))))

(defun cmacs-voice-run-rule (name)
  "Run the rules of the podomation pod spoken NAME best matches.
Through `cmacs-podomation-run-pod': the pod's rules run now, as if its
source had fired.  When no pod matches, `voice_rule' is emitted with
NAME instead, for rules written against that event:
  voice_rule where name == \"standup\" => ..."
  (let ((pod (cmacs-voice-best-name name (cmacs-voice--pod-names))))
    (if (and pod (fboundp 'cmacs-podomation-run-pod))
        (condition-case err
            (cmacs-voice--say "Rule %s (%s)" pod (cmacs-podomation-run-pod pod))
          (error (cmacs-voice--say "Rule %s: %s" pod (error-message-string err))))
      (cmacs-podomation-emit-event
       "voice_rule" (list (cons "name" (string-trim name)) (cons "source" "voice")))
      (cmacs-voice--say "Rule %s" name))))


;;;; The shipped commands

(defun cmacs-voice-commands--define-defaults ()
  "Install the shipped desktop voice commands (after any the user added)."
  (let ((gowl #'cmacs-voice--gowl-p)
        (pod (lambda () (fboundp 'cmacs-podomation-emit-event)))
        (brig (lambda () (fboundp 'cmacs-brigade-call-tool))))
    (dolist (c
             `(;; Workspaces
               ("\\(?:go to \\|switch to \\|show \\)?workspace \\([0-9]+\\)"
                cmacs-voice-workspace "workspace N" (:context desktop :when ,gowl))
               ("\\(?:move\\|send\\|put\\)\\(?: \\(?:this\\|it\\|the window\\|window\\)\\)? to workspace \\([0-9]+\\)"
                cmacs-voice-move-to-workspace "move this to workspace N"
                (:context desktop :when ,gowl))
               ;; Windows
               ("focus \\(left\\|right\\|up\\|down\\)"
                cmacs-voice-focus-direction "focus left/right/up/down"
                (:context desktop :when ,gowl))
               ("\\(?:focus\\|switch to\\|go to\\|show\\)\\(?: window\\)? \\(.+\\)"
                cmacs-voice-focus-window "focus NAME (a window)"
                (:context desktop :when ,gowl))
               ("\\(?:close\\|kill\\|quit\\)\\(?: \\(?:this \\)?window\\)?\\(?: \\(.+\\)\\)?"
                cmacs-voice-close-window "close [window] [NAME]"
                (:context desktop :when ,gowl
                 ;; Asks only when there is something to close; the
                 ;; question names it.
                 :destructive ,(lambda (name)
                                 (when-let* ((label (cdr (cmacs-voice--close-target name))))
                                   (format "Close %s" label)))))
               ("\\(?:toggle \\)?float\\(?:ing\\)? \\(?:this\\|window\\)"
                ,(lambda (&rest _) (when-let* ((c (gowl-focused-client)))
                                     (gowl-toggle-client-floating c)))
                "float this window" (:context desktop :when ,gowl))
               ("\\(?:toggle \\)?full ?screen\\(?: this\\| window\\)?"
                ,(lambda (&rest _) (when-let* ((c (gowl-focused-client)))
                                     (gowl-toggle-client-fullscreen c)))
                "fullscreen" (:context desktop :when ,gowl))
               ;; Layouts
               ("\\(\\(?:tile\\(?: left\\)?\\|tiling\\|tiled\\|monocle\\|tabbed\\|tabs\\|float\\|floating\\|scrolling\\)\\)\\(?: layout\\)?"
                cmacs-voice-set-layout "tile left / monocle / tabbed / float / scrolling"
                (:context desktop :when ,gowl))
               ("\\(?:layout\\|set layout\\|use layout\\|switch layout to\\) \\(.+\\)"
                cmacs-voice-set-layout "layout NAME" (:context desktop :when ,gowl))
               ;; Macros, tools, events
               ("\\(?:run\\|play\\|start\\) macro \\(.+\\)"
                cmacs-voice-run-macro "run macro NAME" (:when ,gowl))
               ("\\(?:use\\|call\\|run\\) tool \\(.+?\\)\\(?: \\(?:for\\|with\\|on\\|about\\) \\(.+\\)\\)?"
                cmacs-voice-run-tool "use tool NAME [for ARG]" (:when ,brig))
               ("\\(?:fire\\|emit\\|trigger\\|send\\) event \\(.+\\)"
                cmacs-voice-emit-event "fire event NAME (podomation)" (:when ,pod))
               ("run rule \\(.+\\)"
                cmacs-voice-run-rule "run rule NAME (a podomation pod)" (:when ,pod))
               ("\\(?:run\\|start\\) \\(.+\\)"
                cmacs-voice-run-named "run NAME (macro, else tool)" (:context desktop))
               ;; Emacs, anywhere
               ("save all\\(?: files\\| buffers\\)?"
                ,(lambda (&rest _) (save-some-buffers t)) "save all" (:context desktop))
               ("save\\(?: \\(?:file\\|buffer\\|this\\)\\)?"
                ,(lambda (&rest _) (call-interactively #'save-buffer)) "save" (:context desktop))
               ("undo\\(?: that\\)?" ,(lambda (&rest _) (call-interactively #'undo))
                "undo" (:context desktop))
               ("\\(?:other\\|next\\) window" ,(lambda (&rest _) (other-window 1))
                "other window" (:context desktop))
               ("\\(?:cancel\\|never ?mind\\|stop listening\\)"
                ,(lambda (&rest _) (message "Voice: cancelled")) "cancel" (:context desktop))
               ("what can i say\\|voice help\\|help"
                ,(lambda (&rest _) (cmacs-voice-commands-help)) "what can I say"
                (:context desktop))))
      (apply #'cmacs-voice-define-command (nth 0 c) (nth 1 c) (nth 2 c) t (nth 3 c)))))

(cmacs-voice-commands--define-defaults)

(provide 'cmacs-voice-commands)

;;; cmacs-voice-commands.el ends here
