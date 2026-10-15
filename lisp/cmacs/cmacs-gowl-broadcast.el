;;; cmacs-gowl-broadcast.el --- Input broadcasting (multiboxing) from Elisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `broadcast' module repeats keys -- and, where a rule asks,
;; clicks -- typed into one window of a TEAM into its other windows, as
;; the same key or another per window: ISBoxer / AutoHotkey multiboxing,
;; done by the compositor, which is the one place on Linux that can put
;; real input into a window without focusing it.  This file is its Elisp
;; surface under `cmacs --gowl'.
;;
;; NOTHING HAPPENS BY DEFAULT.  The module is opt-in: it is loaded only
;; when `cmacs-gowl-broadcast-enable' is non-nil, a team or rule is
;; defined, or `cmacs-gowl-broadcast-start' is called.  Even loaded it
;; repeats nothing until switched on with its toggle key (Super+b, with a
;; toast either way); Super+Shift+b switches it off and releases every
;; key held anywhere.
;;
;; The worked example is three EverQuest clients under Wine (EverQuest's
;; live servers allow boxing; check the rules of the game you play --
;; several forbid broadcasting outright):
;;
;;   (setq cmacs-gowl-broadcast-enable t)
;;   (cmacs-gowl-broadcast-define-team "eq"
;;     :slots '((tank   :match (app-id "eqgame.exe") :focus-key "Super+F1")
;;              (cleric :match (app-id "eqgame.exe") :focus-key "Super+F2")
;;              (wizard :match (app-id "eqgame.exe") :focus-key "Super+F3"))
;;     :groups '((casters cleric wizard)))
;;   (cmacs-gowl-broadcast-define-rule "follow"
;;     :team "eq" :when '(focused-slot "tank")
;;     :keys '("1-9" w a s d) :exclude '(Return slash)
;;     :modifiers 'none :targets 'all-other)
;;   (cmacs-gowl-broadcast-define-rule "heal"
;;     :team "eq" :keys '(h) :targets '(slot cleric) :local 'block
;;     :translate '((cleric (h . "3"))))
;;
;; Everything goes through `gowl-run-command' and the module's
;; `broadcast-' words -- the same ones the IPC socket, MCP and D-Bus
;; reach -- so no new C primitive is involved.  The module's changes of
;; state arrive as the compositor's `module-event' signal, bridged to
;; `cmacs-gowl-module-event-functions', which drives the mode-line
;; lighter and `cmacs-gowl-broadcast-changed-functions'.  See the "Input
;; broadcasting" section of the gowl chapter in the cmacs manual, and
;; deps/gowl/docs/broadcast.org for the schema.

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
(defvar cmacs-gowl-module-event-functions)

(defgroup cmacs-gowl-broadcast nil
  "Input broadcasting (multiboxing) in gowl."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-broadcast-")

(defcustom cmacs-gowl-broadcast-enable nil
  "Non-nil to load gowl's `broadcast' module whenever the compositor starts.
Loading it repeats nothing: broadcasting still waits for the toggle
key.  nil, the default, loads the module only when a team or rule is
defined or `cmacs-gowl-broadcast-start' is called."
  :type 'boolean
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-toggle-key "Super+b"
  "The keybind that switches broadcasting on and off, or nil for none.
Taken before every other bind and while a fullscreen game inhibits
shortcuts, so it works when it is needed; a toast says which way."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-panic-key "Super+Shift+b"
  "The keybind that switches broadcasting off and releases every held key.
nil for none."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-start-on nil
  "Non-nil to broadcast from the start, without pressing the toggle."
  :type 'boolean
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-strict nil
  "Non-nil for strict mode: one key press reaches at most one window.
Rules that could turn a press into input for more than one window are
kept but refused (`cmacs-gowl-broadcast-status' says which).  For games
that allow several clients only on those terms."
  :type 'boolean
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-toast t
  "Non-nil to show toasts on toggle, panic and empty slots."
  :type 'boolean
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-log nil
  "Non-nil to log every repeated key to the journal."
  :type 'boolean
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-max-targets 16
  "At most this many windows get one key (1-64)."
  :type 'integer
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-timeout-ms 80
  "How long one step of an X11 delivery waits for Xwayland (5-2000).
X11 windows -- every game under Wine -- need X focus moved and the key
confirmed processed; this bounds each wait."
  :type 'integer
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-teams nil
  "Teams to install whenever the compositor starts.
Each element is (NAME . PLIST), the arguments of
`cmacs-gowl-broadcast-define-team':

  (\"eq\"
   :slots ((tank :match (app-id \"eqgame.exe\") :focus-key \"Super+F1\")
           (cleric :match (app-id \"eqgame.exe\")))
   :groups ((healers cleric)))"
  :type '(repeat (cons (string :tag "Name") (plist :tag "Team")))
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-rules nil
  "Rules to install whenever the compositor starts.
Each element is (NAME . PLIST), the arguments of
`cmacs-gowl-broadcast-define-rule':

  (\"follow\" :team \"eq\" :when (focused-slot \"tank\")
            :keys (\"1-9\" w a s d) :targets all-other)"
  :type '(repeat (cons (string :tag "Name") (plist :tag "Rule")))
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-changed-functions nil
  "Abnormal hook run when broadcasting is switched on or off.
Each function gets STATE (`on' or `off') and DETAIL, a string: the
focused window's team when switched on (\"-\" for none), or why it went
off (\"panic\", \"lock\", \"deactivated\", or the team).  Fires however it
happened: the toggle key, these commands, the IPC socket, MCP, D-Bus."
  :type 'hook
  :group 'cmacs-gowl-broadcast)

(defcustom cmacs-gowl-broadcast-lighter " BC"
  "What the mode line shows while broadcasting is on; nil for nothing."
  :type '(choice (const :tag "Nothing" nil) string)
  :group 'cmacs-gowl-broadcast)

(defconst cmacs-gowl-broadcast--module "broadcast"
  "The gowl module this file drives.")

(defconst cmacs-gowl-broadcast--slot-fields
  '(app-id title pid xwayland tag tags monitor floating fullscreen)
  "Fields a slot's :match may test (mirrors gowl-broadcast.c).")

(defconst cmacs-gowl-broadcast--rule-fields
  '(team focused-slot app-id title pid xwayland tag tags monitor floating
         fullscreen)
  "Fields a rule's :when may test (mirrors gowl-broadcast.c).")

(defvar cmacs-gowl-broadcast--teams nil
  "Teams defined this session, as (NAME . PLIST), newest first.
Replayed when the compositor (re)starts.")

(defvar cmacs-gowl-broadcast--rules nil
  "Rules defined this session, as (NAME . PLIST), newest first.")

(defvar cmacs-gowl-broadcast--enabled nil
  "Non-nil once the module has been loaded in this compositor.")

(defvar cmacs-gowl-broadcast--on nil
  "Non-nil while broadcasting is on, as the module last announced it.")

(defvar cmacs-gowl-broadcast--team nil
  "The team the module named when it was switched on, or nil.")

;;;; Talking to the module

(defun cmacs-gowl-broadcast--command (line)
  "Run the module command LINE and return the text after \"OK \".
An \"ERROR ...\" reply becomes a `user-error' carrying the module's own
explanation; no reply at all means the module is not loaded."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running"))
  (let ((reply (gowl-run-command line)))
    (cond ((null reply)
           (user-error "The gowl broadcast module is not loaded; call `cmacs-gowl-broadcast-start'"))
          ((string-prefix-p "ERROR" reply)
           (user-error "Broadcast: %s" (string-trim (substring reply 5))))
          ((string-prefix-p "OK " reply) (substring reply 3))
          ((equal reply "OK") "")
          (t reply))))

(defun cmacs-gowl-broadcast--json (line)
  "Run module command LINE and parse its JSON reply into alists."
  (json-parse-string (cmacs-gowl-broadcast--command line)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun cmacs-gowl-broadcast--bool (v)
  "V as the module's \"true\" / \"false\"."
  (if v "true" "false"))

(defun cmacs-gowl-broadcast--settings ()
  "The module settings, as the string alist `gowl-configure-module' takes."
  (list (cons "toggle-key" (or cmacs-gowl-broadcast-toggle-key "none"))
        (cons "panic-key" (or cmacs-gowl-broadcast-panic-key "none"))
        (cons "start-on" (cmacs-gowl-broadcast--bool
                          cmacs-gowl-broadcast-start-on))
        (cons "strict" (cmacs-gowl-broadcast--bool cmacs-gowl-broadcast-strict))
        (cons "toast" (cmacs-gowl-broadcast--bool cmacs-gowl-broadcast-toast))
        (cons "log" (cmacs-gowl-broadcast--bool cmacs-gowl-broadcast-log))
        (cons "max-targets" (number-to-string cmacs-gowl-broadcast-max-targets))
        (cons "timeout-ms" (number-to-string cmacs-gowl-broadcast-timeout-ms))))

;;;###autoload
(defun cmacs-gowl-broadcast-start ()
  "Load gowl's `broadcast' module, push its settings, install every team
and rule defined this session.  Idempotent.  Loading repeats nothing:
broadcasting still waits for the toggle key."
  (interactive)
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running"))
  (unless (gowl-run-command "broadcast-status")
    (gowl-enable-module cmacs-gowl-broadcast--module))
  (condition-case err
      (gowl-configure-module cmacs-gowl-broadcast--module
                             (cmacs-gowl-broadcast--settings))
    (error (message "cmacs-gowl-broadcast: settings failed: %s"
                    (error-message-string err))))
  (setq cmacs-gowl-broadcast--enabled t)
  (cmacs-gowl-broadcast--listen t)
  ;; Teams before rules: a rule names a team
  (dolist (team (reverse cmacs-gowl-broadcast--teams))
    (condition-case err
        (cmacs-gowl-broadcast--send-team (car team) (cdr team))
      (error (message "cmacs-gowl-broadcast: team %s: %s" (car team)
                      (error-message-string err)))))
  (dolist (rule (reverse cmacs-gowl-broadcast--rules))
    (condition-case err
        (cmacs-gowl-broadcast--send-rule (car rule) (cdr rule))
      (error (message "cmacs-gowl-broadcast: rule %s: %s" (car rule)
                      (error-message-string err)))))
  (when (called-interactively-p 'interactive)
    (message "Broadcast: loaded, %s; %s toggles"
             (if cmacs-gowl-broadcast--on "on" "off")
             (or cmacs-gowl-broadcast-toggle-key "nothing"))))

;;;###autoload
(defun cmacs-gowl-broadcast-stop ()
  "Unload the module's effect: off, every held key released.
Teams and rules are kept; `cmacs-gowl-broadcast-start' brings them back."
  (interactive)
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (gowl-disable-module cmacs-gowl-broadcast--module))
  (setq cmacs-gowl-broadcast--enabled nil)
  (cmacs-gowl-broadcast--set-state nil "deactivated"))

(defun cmacs-gowl-broadcast--ensure ()
  "Load the module if this compositor has not got it yet."
  (unless cmacs-gowl-broadcast--enabled
    (cmacs-gowl-broadcast-start)))

;;;; Building teams and rules

(defun cmacs-gowl-broadcast--name (x)
  "X, a symbol, string or number, as a string."
  (cond ((symbolp x) (symbol-name x))
        ((stringp x) x)
        (t (format "%s" x))))

(defun cmacs-gowl-broadcast--word (x what)
  "X as a name: one word, no `:'; WHAT names it in the error."
  (let ((s (cmacs-gowl-broadcast--name x)))
    (when (or (string-empty-p s) (string-match-p "[[:space:]:]" s))
      (user-error "Broadcast: %s %S must be one word without `:'" what s))
    s))

(defun cmacs-gowl-broadcast--delivery (d what)
  "Delivery D (auto, seat or activate) as a string; WHAT for errors."
  (let ((s (cmacs-gowl-broadcast--name d)))
    (unless (member s '("auto" "seat" "activate"))
      (user-error "Broadcast %s: delivery is auto, seat or activate" what))
    s))

(defun cmacs-gowl-broadcast-team-json (name &rest plist)
  "The JSON text of team NAME with PLIST, as the module reads it.
PLIST is what `cmacs-gowl-broadcast-define-team' takes.  JSON is YAML
flow syntax, so this is exactly a `broadcast-add-team' argument."
  (let ((slots (plist-get plist :slots))
        (groups (plist-get plist :groups))
        out-slots out-groups)
    (cl-loop for (key _) on plist by #'cddr
             unless (memq key '(:slots :groups))
             do (user-error "Broadcast team %s: unknown key %s" name key))
    (unless slots
      (user-error "Broadcast team %s: needs :slots" name))
    (dolist (slot slots)
      (let* ((sname (cmacs-gowl-broadcast--word
                     (if (consp slot) (car slot) slot) "slot"))
             (sp (and (consp slot) (cdr slot)))
             (entry `((name . ,sname))))
        (cl-loop for (key _) on sp by #'cddr
                 unless (memq key '(:match :focus-key :delivery))
                 do (user-error "Broadcast team %s slot %s: unknown key %s"
                                name sname key))
        (when (plist-get sp :match)
          (setq entry (append entry
                              `((match . ,(cmacs-gowl-filter-form
                                           (plist-get sp :match)
                                           cmacs-gowl-broadcast--slot-fields
                                           (format "Broadcast slot %s"
                                                   sname)))))))
        (when (plist-get sp :focus-key)
          (setq entry (append entry
                              `((focus-key . ,(plist-get sp :focus-key))))))
        (when (plist-get sp :delivery)
          (setq entry (append entry
                              `((delivery . ,(cmacs-gowl-broadcast--delivery
                                              (plist-get sp :delivery)
                                              name))))))
        (push entry out-slots)))
    (dolist (g groups)
      (unless (consp g)
        (user-error "Broadcast team %s: :groups entries are (NAME SLOT...)"
                    name))
      (push (cons (intern (cmacs-gowl-broadcast--word (car g) "group"))
                  (vconcat (mapcar #'cmacs-gowl-broadcast--name (cdr g))))
            out-groups))
    (json-serialize
     `((name . ,(cmacs-gowl-broadcast--word name "team"))
       (slots . ,(vconcat (nreverse out-slots)))
       ,@(and out-groups `((groups . ,(nreverse out-groups))))))))

(defun cmacs-gowl-broadcast--target (target)
  "TARGET as the module's target text.
`all', `all-other', `current', `under-mouse', (slot NAME), (group NAME),
or the text itself (\"slot:cleric\")."
  (cond ((stringp target) target)
        ((memq target '(all all-other others current under-mouse))
         (symbol-name target))
        ((and (consp target) (memq (car target) '(slot group))
              (= (length target) 2))
         (format "%s:%s" (car target)
                 (cmacs-gowl-broadcast--word (cadr target)
                                             (symbol-name (car target)))))
        (t (user-error "Broadcast: unknown target %S" target))))

(defun cmacs-gowl-broadcast--key (k)
  "Key K -- a symbol, string or number -- as a key name."
  (cmacs-gowl-broadcast--name k))

(defun cmacs-gowl-broadcast-rule-json (name &rest plist)
  "The JSON text of rule NAME with PLIST, as the module reads it.
PLIST is what `cmacs-gowl-broadcast-define-rule' takes."
  (let* ((known '(:team :when :enabled :keys :exclude :modifiers :targets
                        :translate :mode :reset-ms :delivery :mouse
                        :delay-ms :local))
         (rule `((name . ,(cmacs-gowl-broadcast--word name "rule")))))
    (cl-loop for (key _) on plist by #'cddr
             unless (memq key known)
             do (user-error "Broadcast rule %s: unknown key %s" name key))
    (unless (plist-get plist :team)
      (user-error "Broadcast rule %s: needs :team" name))
    (setq rule (append rule `((team . ,(cmacs-gowl-broadcast--word
                                        (plist-get plist :team) "team")))))
    (when (plist-get plist :when)
      (setq rule (append rule
                         `((when . ,(cmacs-gowl-filter-form
                                     (plist-get plist :when)
                                     cmacs-gowl-broadcast--rule-fields
                                     (format "Broadcast rule %s" name)))))))
    (when (plist-member plist :enabled)
      (setq rule (append rule `((enabled . ,(if (plist-get plist :enabled)
                                                t :false))))))
    (when (or (plist-member plist :keys) (plist-member plist :exclude))
      (let ((keys (plist-get plist :keys))
            (exclude (plist-get plist :exclude))
            (k nil))
        (when (plist-member plist :keys)
          (push (cons 'include
                      (if (eq keys 'all) ["all"]
                        (vconcat (mapcar #'cmacs-gowl-broadcast--key
                                         (if (listp keys) keys
                                           (list keys))))))
                k))
        (when exclude
          (push (cons 'exclude (vconcat (mapcar #'cmacs-gowl-broadcast--key
                                                (if (listp exclude) exclude
                                                  (list exclude)))))
                k))
        (setq rule (append rule `((keys . ,(nreverse k)))))))
    (when (plist-get plist :modifiers)
      (let ((m (cmacs-gowl-broadcast--name (plist-get plist :modifiers))))
        (unless (member m '("any" "none"))
          (user-error "Broadcast rule %s: :modifiers is any or none" name))
        (setq rule (append rule `((modifiers . ,m))))))
    (when (plist-get plist :targets)
      (let* ((ts (plist-get plist :targets))
             (lst (if (or (atom ts) (memq (car ts) '(slot group)))
                      (list ts) ts)))
        (setq rule (append rule `((targets . ,(vconcat
                                               (mapcar
                                                #'cmacs-gowl-broadcast--target
                                                lst))))))))
    (when (plist-get plist :translate)
      (let (out)
        (dolist (entry (plist-get plist :translate))
          (unless (and (consp entry) (listp (cdr entry)))
            (user-error "Broadcast rule %s: :translate is ((SLOT (FROM . TO)...)...)"
                        name))
          (push (cons (intern (let ((s (cmacs-gowl-broadcast--name (car entry))))
                                (if (equal s "*") "*"
                                  (cmacs-gowl-broadcast--word s "slot"))))
                      (mapcar (lambda (pair)
                                (unless (consp pair)
                                  (user-error "Broadcast rule %s: a translation is (FROM . TO)"
                                              name))
                                (cons (intern (cmacs-gowl-broadcast--key (car pair)))
                                      (cmacs-gowl-broadcast--key (cdr pair))))
                              (cdr entry)))
                out))
        (setq rule (append rule `((translate . ,(nreverse out)))))))
    (when (plist-get plist :mode)
      (let ((m (cmacs-gowl-broadcast--name (plist-get plist :mode))))
        (unless (member m '("mirror" "round-robin"))
          (user-error "Broadcast rule %s: :mode is mirror or round-robin" name))
        (setq rule (append rule `((mode . ,m))))))
    (dolist (num '(:reset-ms :delay-ms))
      (when (plist-get plist num)
        (unless (natnump (plist-get plist num))
          (user-error "Broadcast rule %s: %s is a number of milliseconds"
                      name num))
        (setq rule (append rule
                           (list (cons (intern (substring (symbol-name num) 1))
                                       (plist-get plist num)))))))
    (when (plist-get plist :delivery)
      (setq rule (append rule
                         `((delivery . ,(cmacs-gowl-broadcast--delivery
                                         (plist-get plist :delivery) name))))))
    (when (plist-get plist :mouse)
      (let ((m (cmacs-gowl-broadcast--name (plist-get plist :mouse))))
        (unless (member m '("off" "same" "scaled"))
          (user-error "Broadcast rule %s: :mouse is off, same or scaled" name))
        (setq rule (append rule `((mouse . ,m))))))
    (when (plist-get plist :local)
      (let ((l (cmacs-gowl-broadcast--name (plist-get plist :local))))
        (unless (member l '("pass" "block"))
          (user-error "Broadcast rule %s: :local is pass or block" name))
        (setq rule (append rule `((local . ,l))))))
    (json-serialize rule)))

(defun cmacs-gowl-broadcast--send-team (name plist)
  "Send team NAME with PLIST to the module; return its reply."
  (cmacs-gowl-broadcast--command
   (concat "broadcast-add-team "
           (apply #'cmacs-gowl-broadcast-team-json name plist))))

(defun cmacs-gowl-broadcast--send-rule (name plist)
  "Send rule NAME with PLIST to the module; return its reply."
  (let ((reply (cmacs-gowl-broadcast--command
                (concat "broadcast-add-rule "
                        (apply #'cmacs-gowl-broadcast-rule-json name plist)))))
    (when (string-match-p "cannot run" reply)
      (message "Broadcast: rule %s %s" name reply))
    reply))

;;;###autoload
(defun cmacs-gowl-broadcast-define-team (name &rest plist)
  "Define broadcast team NAME, replacing one of the same name.
PLIST keys:

  :slots LIST    each a name, or (NAME :match FORM :focus-key KEY
                 :delivery auto|seat|activate).  FORM is a filter over
                 the window -- (app-id \"eqgame.exe\"), (and (app-id ...)
                 (title ~ \"Tank\")) -- with the fields in
                 `cmacs-gowl-broadcast--slot-fields', or filter text.
                 Slots are filled in order, each by the first window its
                 match accepts that holds no other slot; a slot without
                 :match is filled only by hand
                 (`cmacs-gowl-broadcast-assign').  :focus-key focuses
                 the slot's window from anywhere.
  :groups LIST   (NAME SLOT...) named subsets for (group NAME) targets.

When the compositor is not running yet, the team is kept and installed
when it starts."
  (let ((name (cmacs-gowl-broadcast--word name "team")))
    (apply #'cmacs-gowl-broadcast-team-json name plist)
    (setq cmacs-gowl-broadcast--teams
          (cons (cons name plist)
                (assoc-delete-all name cmacs-gowl-broadcast--teams)))
    (when (and (fboundp 'gowl-running-p) (gowl-running-p))
      (if cmacs-gowl-broadcast--enabled
          (cmacs-gowl-broadcast--send-team name plist)
        (cmacs-gowl-broadcast-start)))
    name))

;;;###autoload
(defun cmacs-gowl-broadcast-define-rule (name &rest plist)
  "Define broadcast rule NAME, replacing one of the same name.
PLIST keys (only :team is required):

  :team NAME        the team whose windows it is about
  :when FORM        a filter over the focused window, with the fields in
                    `cmacs-gowl-broadcast--rule-fields' -- usually
                    (focused-slot \"leader\")
  :enabled BOOL     nil keeps it defined but out of force
  :keys LIST        key names or ranges (\"1-9\", \"F1-F12\", w, space);
                    `all' or omitted for every key, nil (with :keys
                    given) for none -- a clicks-only rule
  :exclude LIST     keys never repeated
  :modifiers none   repeat only while no Ctrl/Alt/Super is held
  :targets T        `all', `all-other' (default), `current',
                    `under-mouse', (slot NAME), (group NAME), or a list
  :translate LIST   ((SLOT (FROM . TO)...)...), SLOT `*' for every
                    target without its own; TO may carry modifiers
                    (\"Shift+2\")
  :mode M           `mirror' (default) or `round-robin'
  :reset-ms N       round-robin starts over after N idle milliseconds
  :delivery D       `auto', `seat' or `activate'
  :mouse M          `off' (default), `same' or `scaled': repeat clicks
  :delay-ms N       pause between one target and the next
  :local L          `pass' (default) or `block': keep the key from the
                    focused window

When the compositor is not running yet, the rule is kept and installed
when it starts."
  (let ((name (cmacs-gowl-broadcast--word name "rule")))
    (apply #'cmacs-gowl-broadcast-rule-json name plist)
    (setq cmacs-gowl-broadcast--rules
          (cons (cons name plist)
                (assoc-delete-all name cmacs-gowl-broadcast--rules)))
    (when (and (fboundp 'gowl-running-p) (gowl-running-p))
      (if cmacs-gowl-broadcast--enabled
          (cmacs-gowl-broadcast--send-rule name plist)
        (cmacs-gowl-broadcast-start)))
    name))

;;;; State

(defun cmacs-gowl-broadcast-status ()
  "The module's state, as an alist (see the module's `broadcast-status').
Interactively, a summary in the echo area."
  (interactive)
  (let ((s (cmacs-gowl-broadcast--json "broadcast-status")))
    (when (called-interactively-p 'interactive)
      (let ((focused (alist-get 'focused s)))
        (message "Broadcast %s%s -- %d team(s), %d rule(s)%s; focused: %s"
                 (if (alist-get 'on s) "ON" "off")
                 (if (alist-get 'strict s) " (strict)" "")
                 (length (alist-get 'teams s))
                 (length (alist-get 'rules s))
                 (let ((bad (cl-count-if (lambda (r) (alist-get 'problem r))
                                         (alist-get 'rules s))))
                   (if (> bad 0) (format ", %d cannot run" bad) ""))
                 (if (alist-get 'team focused)
                     (format "%s/%s" (alist-get 'team focused)
                             (alist-get 'slot focused))
                   "no team"))))
    s))

(defun cmacs-gowl-broadcast-list ()
  "Every team and rule in force, as (teams . YAML-LIST) and (rules . ...)."
  (cmacs-gowl-broadcast--json "broadcast-list"))

(defun cmacs-gowl-broadcast--switch (verb)
  "Run broadcast VERB (on, off, toggle, panic); report and return the state."
  (cmacs-gowl-broadcast--ensure)
  (let ((reply (cmacs-gowl-broadcast--command (concat "broadcast-" verb))))
    (message "Broadcast %s" (if (equal reply "on") "ON" "off"))
    reply))

;;;###autoload
(defun cmacs-gowl-broadcast-toggle ()
  "Switch broadcasting on or off (what the toggle key does)."
  (interactive)
  (cmacs-gowl-broadcast--switch "toggle"))

;;;###autoload
(defun cmacs-gowl-broadcast-on ()
  "Switch broadcasting on."
  (interactive)
  (cmacs-gowl-broadcast--switch "on"))

;;;###autoload
(defun cmacs-gowl-broadcast-off ()
  "Switch broadcasting off, releasing every key it holds anywhere."
  (interactive)
  (cmacs-gowl-broadcast--switch "off"))

;;;###autoload
(defun cmacs-gowl-broadcast-panic ()
  "Off, and every key held in any window released (what the panic key does)."
  (interactive)
  (cmacs-gowl-broadcast--switch "panic"))

(defun cmacs-gowl-broadcast-strict (&optional arg)
  "Toggle strict mode; with a positive ARG on, zero or negative off."
  (interactive "P")
  (let ((reply (cmacs-gowl-broadcast--command
                (concat "broadcast-strict "
                        (cond ((null arg) "toggle")
                              ((> (prefix-numeric-value arg) 0) "on")
                              (t "off"))))))
    (message "Broadcast strict %s" reply)
    reply))

(defun cmacs-gowl-broadcast--team-names ()
  "The names of the teams in force."
  (mapcar (lambda (team) (alist-get 'name team))
          (alist-get 'teams (cmacs-gowl-broadcast-status))))

(defun cmacs-gowl-broadcast--slot-names (team)
  "The slot names of TEAM."
  (let ((entry (cl-find team (alist-get 'teams (cmacs-gowl-broadcast-status))
                        :key (lambda (x) (alist-get 'name x)) :test #'equal)))
    (mapcar (lambda (s) (alist-get 'name s)) (alist-get 'slots entry))))

(defun cmacs-gowl-broadcast--read-team-slot ()
  "Read a team and a slot with completion; return (TEAM SLOT)."
  (let* ((team (completing-read "Team: " (cmacs-gowl-broadcast--team-names)
                                nil t))
         (slot (completing-read (format "Slot of %s: " team)
                                (cmacs-gowl-broadcast--slot-names team)
                                nil t)))
    (list team slot)))

;;;###autoload
(defun cmacs-gowl-broadcast-assign (team slot &optional client-id)
  "Put window CLIENT-ID -- the focused one by default -- in SLOT of TEAM.
Holds until that window closes; `cmacs-gowl-broadcast-unassign' hands
the slot back to its :match."
  (interactive (cmacs-gowl-broadcast--read-team-slot))
  (let ((reply (cmacs-gowl-broadcast--command
                (format "broadcast-assign %s %s%s"
                        (cmacs-gowl-broadcast--word team "team")
                        (cmacs-gowl-broadcast--word slot "slot")
                        (if client-id (format " %d" client-id) "")))))
    (when (called-interactively-p 'interactive)
      (message "Broadcast: %s" reply))
    reply))

(defun cmacs-gowl-broadcast-unassign (team slot)
  "Return SLOT of TEAM to its :match."
  (interactive (cmacs-gowl-broadcast--read-team-slot))
  (cmacs-gowl-broadcast--command
   (format "broadcast-unassign %s %s"
           (cmacs-gowl-broadcast--word team "team")
           (cmacs-gowl-broadcast--word slot "slot"))))

;;;###autoload
(defun cmacs-gowl-broadcast-focus-slot (team slot)
  "Focus the window in SLOT of TEAM, viewing its tag."
  (interactive (cmacs-gowl-broadcast--read-team-slot))
  (cmacs-gowl-broadcast--command
   (format "broadcast-focus-slot %s %s"
           (cmacs-gowl-broadcast--word team "team")
           (cmacs-gowl-broadcast--word slot "slot"))))

(defun cmacs-gowl-broadcast-remove-team (name)
  "Remove broadcast team NAME (keys it held are released first)."
  (interactive (list (completing-read "Remove team: "
                                      (cmacs-gowl-broadcast--team-names)
                                      nil t)))
  (setq cmacs-gowl-broadcast--teams
        (assoc-delete-all name cmacs-gowl-broadcast--teams))
  (cmacs-gowl-broadcast--command (concat "broadcast-remove-team " name)))

(defun cmacs-gowl-broadcast-remove-rule (name)
  "Remove broadcast rule NAME."
  (interactive
   (list (completing-read "Remove rule: "
                          (mapcar (lambda (r) (alist-get 'name r))
                                  (alist-get 'rules
                                             (cmacs-gowl-broadcast-status)))
                          nil t)))
  (setq cmacs-gowl-broadcast--rules
        (assoc-delete-all name cmacs-gowl-broadcast--rules))
  (cmacs-gowl-broadcast--command (concat "broadcast-remove-rule " name)))

(defun cmacs-gowl-broadcast-set-rule-enabled (name enabled)
  "Put rule NAME in force (ENABLED non-nil) or take it out, keeping it."
  (cmacs-gowl-broadcast--command
   (format "broadcast-%s-rule %s" (if enabled "enable" "disable")
           (cmacs-gowl-broadcast--word name "rule"))))

(defun cmacs-gowl-broadcast-clear ()
  "Forget every team, rule and hand assignment added at runtime.
The config's teams and rules stay."
  (interactive)
  (setq cmacs-gowl-broadcast--teams nil
        cmacs-gowl-broadcast--rules nil)
  (cmacs-gowl-broadcast--command "broadcast-clear"))

;;;; Hearing the module

(defun cmacs-gowl-broadcast--set-state (on detail)
  "Record ON and DETAIL, update the lighter, run the changed hook."
  (setq cmacs-gowl-broadcast--on on
        cmacs-gowl-broadcast--team (and on (not (equal detail "-")) detail))
  (force-mode-line-update t)
  (run-hook-with-args 'cmacs-gowl-broadcast-changed-functions
                      (if on 'on 'off) detail))

(defun cmacs-gowl-broadcast--on-module-event (module text)
  "Handle a gowl `module-event' from MODULE carrying TEXT.
The broadcast module announces \"on TEAM\", \"off DETAIL\" and
\"strict on|off\"."
  (when (equal module cmacs-gowl-broadcast--module)
    (let ((words (split-string (or text "") " " t)))
      (pcase (car words)
        ("on" (cmacs-gowl-broadcast--set-state t (or (cadr words) "-")))
        ("off" (cmacs-gowl-broadcast--set-state nil (or (cadr words) "-")))))))

(defun cmacs-gowl-broadcast--listen (on)
  "Listen to the module's events (ON non-nil), or stop."
  (if on
      (add-hook 'cmacs-gowl-module-event-functions
                #'cmacs-gowl-broadcast--on-module-event)
    (remove-hook 'cmacs-gowl-module-event-functions
                 #'cmacs-gowl-broadcast--on-module-event)))

(defun cmacs-gowl-broadcast--lighter ()
  "The mode-line text while broadcasting, or nil."
  (and cmacs-gowl-broadcast--on cmacs-gowl-broadcast-lighter
       (propertize cmacs-gowl-broadcast-lighter
                   'face 'warning
                   'help-echo (format "Broadcasting%s\n%s toggles, %s panics"
                                      (if cmacs-gowl-broadcast--team
                                          (format " -- team %s"
                                                  cmacs-gowl-broadcast--team)
                                        "")
                                      (or cmacs-gowl-broadcast-toggle-key "nothing")
                                      (or cmacs-gowl-broadcast-panic-key "nothing")))))

(defconst cmacs-gowl-broadcast--mode-line-entry
  '(:eval (cmacs-gowl-broadcast--lighter))
  "The `mode-line-misc-info' entry for broadcasting.")

(add-to-list 'mode-line-misc-info cmacs-gowl-broadcast--mode-line-entry t)

;;;; A buffer of teams and slots

(defvar-keymap cmacs-gowl-broadcast-mode-map
  :doc "Keys in the broadcast buffer."
  "t" #'cmacs-gowl-broadcast-toggle
  "p" #'cmacs-gowl-broadcast-panic
  "s" #'cmacs-gowl-broadcast-strict
  "a" #'cmacs-gowl-broadcast-assign-at-point
  "u" #'cmacs-gowl-broadcast-unassign-at-point
  "RET" #'cmacs-gowl-broadcast-focus-at-point)

(define-derived-mode cmacs-gowl-broadcast-mode tabulated-list-mode
  "Broadcast"
  "Every team's slots, the window in each, and the rules in force.
\\<cmacs-gowl-broadcast-mode-map>
\\[cmacs-gowl-broadcast-toggle] toggles broadcasting, \\[cmacs-gowl-broadcast-panic] panics, \\[cmacs-gowl-broadcast-strict] toggles strict mode,
\\[cmacs-gowl-broadcast-focus-at-point] focuses the slot's window, \\[cmacs-gowl-broadcast-assign-at-point] asks for a window to put in
it, \\[cmacs-gowl-broadcast-unassign-at-point] hands it back to its match, and \\[revert-buffer] refreshes."
  (setq tabulated-list-format
        [("Team" 10 t)
         ("Slot" 10 t)
         ("Id" 5 t :right-align t)
         ("Window" 40 t)
         ("Match" 0 t)])
  (add-hook 'tabulated-list-revert-hook
            #'cmacs-gowl-broadcast--buffer-refresh nil t)
  (tabulated-list-init-header))

(defun cmacs-gowl-broadcast--buffer-refresh ()
  "Fill the broadcast buffer from the module."
  (let* ((s (cmacs-gowl-broadcast-status))
         (rows nil))
    (dolist (team (alist-get 'teams s))
      (dolist (slot (alist-get 'slots team))
        (let ((client (alist-get 'client slot)))
          (push (list (cons (alist-get 'name team) (alist-get 'name slot))
                      (vector (alist-get 'name team)
                              (alist-get 'name slot)
                              (if client
                                  (number-to-string (alist-get 'id client))
                                "-")
                              (if client
                                  (format "%s  %s" (alist-get 'app_id client)
                                          (alist-get 'title client))
                                "(empty)")
                              (or (alist-get 'match slot) "(by hand)")))
                rows))))
    (setq tabulated-list-entries (nreverse rows))
    (setq header-line-format
          (format " Broadcast %s%s   rules: %s"
                  (if (alist-get 'on s) "ON" "off")
                  (if (alist-get 'strict s) " (strict)" "")
                  (mapconcat (lambda (r)
                               (format "%s%s" (alist-get 'name r)
                                       (cond ((alist-get 'problem r) "!")
                                             ((not (alist-get 'enabled r)) "-")
                                             (t ""))))
                             (alist-get 'rules s) " ")))))

(defun cmacs-gowl-broadcast--at-point ()
  "The (TEAM . SLOT) of the line at point."
  (or (tabulated-list-get-id) (user-error "No slot on this line")))

(defun cmacs-gowl-broadcast-focus-at-point ()
  "Focus the window of the slot at point."
  (interactive)
  (let ((id (cmacs-gowl-broadcast--at-point)))
    (cmacs-gowl-broadcast-focus-slot (car id) (cdr id))))

(defun cmacs-gowl-broadcast-assign-at-point (client-id)
  "Put window CLIENT-ID in the slot at point."
  (interactive "nWindow id: ")
  (let ((id (cmacs-gowl-broadcast--at-point)))
    (cmacs-gowl-broadcast-assign (car id) (cdr id) client-id)
    (revert-buffer)))

(defun cmacs-gowl-broadcast-unassign-at-point ()
  "Hand the slot at point back to its :match."
  (interactive)
  (let ((id (cmacs-gowl-broadcast--at-point)))
    (cmacs-gowl-broadcast-unassign (car id) (cdr id))
    (revert-buffer)))

;;;###autoload
(defun cmacs-gowl-broadcast-show ()
  "List every team's slots and the window in each."
  (interactive)
  (cmacs-gowl-broadcast--ensure)
  (with-current-buffer (get-buffer-create "*gowl broadcast*")
    (cmacs-gowl-broadcast-mode)
    (cmacs-gowl-broadcast--buffer-refresh)
    (tabulated-list-print)
    (pop-to-buffer (current-buffer))))

;;;; RPC (D-Bus, MCP)

(defun cmacs-gowl-broadcast-rpc (verb)
  "Run broadcast VERB for an RPC caller; never signal.
VERB is \"status\", \"list\", \"on\", \"off\", \"toggle\" or \"panic\".
Returns the module's reply text, or \"ERROR ...\"."
  (condition-case err
      (if (member verb '("status" "list" "on" "off" "toggle" "panic"))
          (progn
            (unless (member verb '("status" "list"))
              (cmacs-gowl-broadcast--ensure))
            (cmacs-gowl-broadcast--command (concat "broadcast-" verb)))
        (format "ERROR unknown broadcast verb %s" verb))
    (error (concat "ERROR " (error-message-string err)))))

(defun cmacs-gowl-broadcast-command (line)
  "Run the module command LINE (\"broadcast-...\"); return its reply.
For MCP: an error comes back as \"ERROR ...\" text, never a signal."
  (condition-case err
      (if (string-prefix-p "broadcast-" line)
          (progn
            (unless (member line '("broadcast-status" "broadcast-list"))
              (cmacs-gowl-broadcast--ensure))
            (cmacs-gowl-broadcast--command line))
        "ERROR not a broadcast- command")
    (error (concat "ERROR " (error-message-string err)))))

;;;; Startup

(defun cmacs-gowl-broadcast--on-start ()
  "Install the module and the configured teams and rules, if asked to.
Called by `cmacs-gowl-mode' when the compositor (re)starts.  Does
nothing, and loads nothing, unless `cmacs-gowl-broadcast-enable' is set
or a team or rule is defined."
  (setq cmacs-gowl-broadcast--enabled nil)
  (cmacs-gowl-broadcast--set-state nil "-")
  (dolist (team cmacs-gowl-broadcast-teams)
    (unless (assoc (car team) cmacs-gowl-broadcast--teams)
      (push team cmacs-gowl-broadcast--teams)))
  (dolist (rule cmacs-gowl-broadcast-rules)
    (unless (assoc (car rule) cmacs-gowl-broadcast--rules)
      (push rule cmacs-gowl-broadcast--rules)))
  (when (or cmacs-gowl-broadcast-enable cmacs-gowl-broadcast--teams
            cmacs-gowl-broadcast--rules)
    (condition-case err
        (cmacs-gowl-broadcast-start)
      (error (message "cmacs-gowl-broadcast: %s"
                      (error-message-string err))))))

(provide 'cmacs-gowl-broadcast)

;;; cmacs-gowl-broadcast.el ends here
