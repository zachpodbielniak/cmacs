;;; cmacs-gowl-input-remap.el --- Per-device input remapping from Elisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `inputremap' module remaps keys, buttons and wheel notches on
;; ONE physical device -- a foot pedal, a macro pad, one particular
;; mouse -- without touching any other device that sends the same codes.
;; This file is its Elisp surface under `cmacs --gowl'.
;;
;; NOTHING HAPPENS BY DEFAULT.  The module is opt-in: it is loaded only
;; when you define a rule, set `cmacs-gowl-input-remap-rules', or call
;; `cmacs-gowl-input-remap-enable'.  cmacs ships no rule and binds no
;; key for it.
;;
;; The worked example is a 2-pedal switch for World of Warcraft:
;;
;;   (cmacs-gowl-input-remap-define "wow-pedals"
;;     :match '(:id "1a86:e026" :type keyboard)
;;     :unmatched 'drop
;;     :map '((KEY_A . (button middle))
;;            (KEY_B . (action focus-client "title:World of Warcraft*"))))
;;
;; Pedal A is one middle click at the cursor (a fishing addon's single
;; keybind); pedal B views WoW's tag and focuses it -- a compositor
;; action, so nothing at all is sent to the game.
;;
;; Every input maps to exactly ONE output and the release mirrors the
;; press.  The module refuses macros, sequences, delays and repeats; so
;; does this file, before anything is sent.  The one exception is a
;; FUNCTION target: arbitrary Elisp, run on the press.  It runs on the
;; main thread, never the compositor's -- the module fires a `custom'
;; action whose form calls back in here through the same idle dispatch
;; every custom keybind uses.  What that code does is your business.
;;
;; Everything goes through `gowl-run-command' and the module's
;; `inputremap-' words, the same ones the IPC socket, MCP and D-Bus
;; reach, so no new C primitive is involved.  See the "Per-device input
;; remapping" section of the gowl chapter in the cmacs manual, and
;; deps/gowl/docs/input-remap.org for the rule schema.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)

(declare-function gowl-run-command "cmacs-gowl")
(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-enable-module "cmacs-gowl")
(declare-function gowl-disable-module "cmacs-gowl")
(declare-function gowl-configure-module "cmacs-gowl")

(defgroup cmacs-gowl-input-remap nil
  "Per-device input remapping in gowl."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-input-remap-")

(defcustom cmacs-gowl-input-remap-rules nil
  "Per-device remap rules to install whenever the compositor starts.
Each element is (NAME . PLIST), the arguments of
`cmacs-gowl-input-remap-define':

  (\"wow-pedals\"
   :match (:id \"1a86:e026\" :type keyboard)
   :unmatched drop
   :map ((KEY_A . (button middle))
         (KEY_B . (action focus-client \"title:World of Warcraft*\"))))

nil, the default, loads nothing: the `inputremap' module stays
unloaded until a rule is defined or `cmacs-gowl-input-remap-enable'
is called."
  :type '(repeat (cons (string :tag "Name") (plist :tag "Rule")))
  :group 'cmacs-gowl-input-remap)

(defcustom cmacs-gowl-input-remap-log 'claim
  "How much the `inputremap' module logs.
`none', `claim' (devices claimed and released), `match' (also every
remapped press) or `all' (also presses that pass through).  A rule
with `:log t' is logged at `match' whatever this says."
  :type '(choice (const none) (const claim) (const match) (const all))
  :group 'cmacs-gowl-input-remap)

(defcustom cmacs-gowl-input-remap-log-file nil
  "Where the module logs: a file name, or nil for stderr."
  :type '(choice (const :tag "stderr" nil) file)
  :group 'cmacs-gowl-input-remap)

(defcustom cmacs-gowl-input-remap-identify-timeout 10
  "Seconds `cmacs-gowl-input-remap-identify' waits for a press."
  :type '(integer :tag "Seconds")
  :group 'cmacs-gowl-input-remap)

(defcustom cmacs-gowl-input-remap-identified-functions nil
  "Abnormal hook run when identify mode catches a press.
Each function gets one argument, an alist with `device' (itself an
alist: `id', `type', `name', `vendor-product', `sysname', `claimed')
and `input' (the input name, such as \"KEY_A\")."
  :type 'hook
  :group 'cmacs-gowl-input-remap)

(defconst cmacs-gowl-input-remap--module "inputremap"
  "The gowl module this file drives.")

(defconst cmacs-gowl-input-remap--forbidden
  '(:sequence :macro :delay :repeat :keys :then :chain :times)
  "Keys that would make a target more than one output.  Refused.")

(defvar cmacs-gowl-input-remap--defined nil
  "Rules defined this session, as (NAME . PLIST), newest first.
Replayed when the compositor (re)starts, so a rule defined in the init
file before `cmacs-gowl-mode' is not lost.")

(defvar cmacs-gowl-input-remap--functions (make-hash-table :test #'equal)
  "Function targets: \"RULE/INPUT\" -> the function to call.")

(defvar cmacs-gowl-input-remap--enabled nil
  "Non-nil once the module has been enabled in this compositor.")

;;;; Talking to the module

(defun cmacs-gowl-input-remap--command (line)
  "Run the module command LINE and return the text after \"OK \".
An \"ERROR ...\" reply becomes a `user-error' carrying the module's
own explanation; no reply at all means the module is not loaded."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running"))
  (let ((reply (gowl-run-command line)))
    (cond ((null reply)
           (user-error "The gowl inputremap module is not loaded; call `cmacs-gowl-input-remap-enable'"))
          ((string-prefix-p "ERROR" reply)
           (user-error "Input remap: %s" (string-trim (substring reply 5))))
          ((string-prefix-p "OK " reply) (substring reply 3))
          ((equal reply "OK") "")
          (t reply))))

(defun cmacs-gowl-input-remap--json (line)
  "Run module command LINE and parse its JSON reply into alists."
  (json-parse-string (cmacs-gowl-input-remap--command line)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun cmacs-gowl-input-remap--settings ()
  "The module settings, as the string alist `gowl-configure-module' takes."
  (append
   (list (cons "log" (symbol-name cmacs-gowl-input-remap-log))
         (cons "identify-timeout"
               (number-to-string cmacs-gowl-input-remap-identify-timeout)))
   (list (cons "log-file" (if cmacs-gowl-input-remap-log-file
                              (expand-file-name cmacs-gowl-input-remap-log-file)
                            "stderr")))))

;;;###autoload
(defun cmacs-gowl-input-remap-enable ()
  "Load and enable gowl's `inputremap' module, and push its settings.
Idempotent.  Rules already defined this session are (re)installed."
  (interactive)
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running"))
  (unless (gowl-run-command "inputremap-status")
    (gowl-enable-module cmacs-gowl-input-remap--module))
  (condition-case err
      (gowl-configure-module cmacs-gowl-input-remap--module
                             (cmacs-gowl-input-remap--settings))
    (error (message "cmacs-gowl-input-remap: settings failed: %s"
                    (error-message-string err))))
  (setq cmacs-gowl-input-remap--enabled t)
  (dolist (rule (reverse cmacs-gowl-input-remap--defined))
    (condition-case err
        (cmacs-gowl-input-remap--send (car rule) (cdr rule))
      (error (message "cmacs-gowl-input-remap: rule %s: %s" (car rule)
                      (error-message-string err)))))
  (when (called-interactively-p 'interactive)
    (message "Input remap: %s" (cmacs-gowl-input-remap--command
                                "inputremap-status"))))

;;;###autoload
(defun cmacs-gowl-input-remap-disable ()
  "Disable the `inputremap' module: every claimed device is released.
The rules are kept; `cmacs-gowl-input-remap-enable' brings them back."
  (interactive)
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (gowl-disable-module cmacs-gowl-input-remap--module))
  (setq cmacs-gowl-input-remap--enabled nil))

;;;; Building a rule

(defun cmacs-gowl-input-remap--name (x)
  "X, a symbol or string, as a string."
  (if (symbolp x) (symbol-name x) (format "%s" x)))

(defun cmacs-gowl-input-remap--target (rule input target)
  "The JSON value for TARGET, the output INPUT of RULE maps to.
TARGET is one of:
  `pass', `drop'                      deliver unchanged / swallow
  (key \"Super+9\") or (key KEY_F13)   one key, modifiers held for it
  (button middle)                     one pointer button at the cursor
  (action ACTION [ARG])               one compositor action, on press
  (command \"LINE\")                    one module command, on press
  a function                          Elisp, called on the press
Anything holding more than one output is refused."
  (cond
   ((memq target '(pass drop)) (symbol-name target))
   ((member target '("pass" "drop")) target)
   ((and (consp target) (memq (car target) '(key button action command)))
    (let ((kind (car target))
          (args (cdr target)))
      (when (cl-some (lambda (a) (memq a cmacs-gowl-input-remap--forbidden))
                     args)
        (user-error "Input remap %s/%s: one input maps to one output -- no sequences, macros, delays or repeats"
                    rule input))
      (pcase kind
        ('action
         (unless (and args (<= (length args) 2))
           (user-error "Input remap %s/%s: (action NAME [ARG])" rule input))
         (append (list (cons 'action (cmacs-gowl-input-remap--name (car args))))
                 (and (cdr args)
                      (list (cons 'arg (format "%s" (cadr args)))))))
        (_
         (unless (= (length args) 1)
           (user-error "Input remap %s/%s: (%s VALUE) takes exactly one value"
                       rule input kind))
         (when (consp (car args))
           (user-error "Input remap %s/%s: %s is a list; one input maps to one output"
                       rule input kind))
         (list (cons kind (cmacs-gowl-input-remap--name (car args))))))))
   ((functionp target)
    ;; Elisp runs on the main thread: the module fires a `custom' action
    ;; and cmacs evaluates its form from the idle dispatch.  Only string
    ;; literals go into the form, printed with `prin1-to-string'.
    (puthash (format "%s/%s" rule input) target
             cmacs-gowl-input-remap--functions)
    (list (cons 'action "custom")
          (cons 'arg (format "(cmacs-gowl-input-remap--call %s %s)"
                             (prin1-to-string rule)
                             (prin1-to-string input)))))
   ((and (consp target) (listp (car target)))
    (user-error "Input remap %s/%s: a list of targets is a sequence; one input maps to one output"
                rule input))
   (t (user-error "Input remap %s/%s: unknown target %S" rule input target))))

(defun cmacs-gowl-input-remap--match (rule match)
  "The JSON `match' object for MATCH, the device plist of RULE.
Keys: `:name' (glob on the device name), `:id' (\"VVVV:PPPP\" hex),
`:vendor' and `:product' (integers or hex strings), `:sysname' (glob)
and `:type' (`keyboard', `pointer' or `any')."
  (let (out)
    (cl-loop for (key value) on match by #'cddr do
             (pcase key
               ((or :name :sysname :id)
                (push (cons (intern (substring (symbol-name key) 1))
                            (format "%s" value))
                      out))
               ((or :vendor :product)
                (push (cons (intern (substring (symbol-name key) 1))
                            (if (integerp value) (format "0x%04x" value)
                              (format "%s" value)))
                      out))
               (:type
                (push (cons 'type (cmacs-gowl-input-remap--name value)) out))
               (_ (user-error "Input remap %s: unknown match key %s"
                              rule key))))
    (unless (cl-some (lambda (c) (memq (car c) '(name sysname id vendor product)))
                     out)
      (user-error "Input remap %s: :match needs :name, :id, :vendor, :product or :sysname"
                  rule))
    (nreverse out)))

(defun cmacs-gowl-input-remap-rule-json (name &rest plist)
  "The JSON text of rule NAME with PLIST, as the module reads it.
PLIST is what `cmacs-gowl-input-remap-define' takes.  JSON is YAML
flow syntax, so this is exactly an `inputremap-add' argument.  Also
the place every one-to-one check on the Elisp side happens."
  (let* ((match (plist-get plist :match))
         (map (plist-get plist :map))
         (unmatched (plist-get plist :unmatched))
         (log (plist-get plist :log))
         (rule `((name . ,name)
                 (match . ,(cmacs-gowl-input-remap--match name match))))
         (pairs nil))
    (cl-loop for (key _) on plist by #'cddr
             unless (memq key '(:match :map :unmatched :log))
             do (user-error "Input remap %s: unknown key %s%s" name key
                            (if (memq key cmacs-gowl-input-remap--forbidden)
                                " -- one input maps to one output" "")))
    (when unmatched
      (unless (memq (intern (cmacs-gowl-input-remap--name unmatched))
                    '(pass drop))
        (user-error "Input remap %s: :unmatched is pass or drop" name))
      (setq rule (append rule `((unmatched . ,(cmacs-gowl-input-remap--name
                                               unmatched))))))
    (when log
      (setq rule (append rule '((log . t)))))
    ;; One entry per input; a repeated input would be two outputs.
    (dolist (entry map)
      (unless (consp entry)
        (user-error "Input remap %s: :map entries are (INPUT . TARGET)" name))
      (let ((input (cmacs-gowl-input-remap--name (car entry))))
        (when (assoc input pairs)
          (user-error "Input remap %s: %s is mapped twice; one input maps to one output"
                      name input))
        (push (cons input (cmacs-gowl-input-remap--target name input
                                                          (cdr entry)))
              pairs)))
    ;; An empty map is an empty object (a hash table serializes as {};
    ;; nil would be null)
    (setq rule (append rule
                       `((map . ,(or (mapcar (lambda (p)
                                               (cons (intern (car p)) (cdr p)))
                                             (nreverse pairs))
                                     (make-hash-table))))))
    (json-serialize rule)))

(defun cmacs-gowl-input-remap--send (name plist)
  "Send rule NAME with PLIST to the module; return its reply."
  (cmacs-gowl-input-remap--command
   (concat "inputremap-add "
           (apply #'cmacs-gowl-input-remap-rule-json name plist))))

;;;###autoload
(defun cmacs-gowl-input-remap-define (name &rest plist)
  "Define per-device remap rule NAME, replacing one of the same name.
PLIST keys:

  :match PLIST    which devices: :name GLOB, :id \"VVVV:PPPP\",
                  :vendor N, :product N, :sysname GLOB,
                  :type keyboard|pointer|any.  At least one of the
                  first five is required.
  :map ALIST      (INPUT . TARGET) pairs.  INPUT is a KEY_* or BTN_*
                  name, left/middle/right/side/extra, or
                  WHEEL_UP/DOWN/LEFT/RIGHT, as a symbol or string.
  :unmatched      `pass' (default) or `drop': inputs :map leaves out.
  :log            non-nil to log every remap this rule makes.

TARGET is `pass', `drop', (key \"Super+9\"), (key KEY_F13),
\(button middle), (action ACTION [ARG]), (command \"LINE\"), or a
function called with the rule name and input on the press, on the
main thread.  One input, one output: lists and delays are refused.

Loads the module the first time.  When the compositor is not running
yet, the rule is kept and installed when it starts."
  (unless (and (stringp name) (not (string-empty-p name)))
    (user-error "Input remap: a rule needs a name"))
  ;; Validate now, even when nothing can be sent yet.
  (apply #'cmacs-gowl-input-remap-rule-json name plist)
  (setq cmacs-gowl-input-remap--defined
        (cons (cons name plist)
              (assoc-delete-all name cmacs-gowl-input-remap--defined)))
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (unless cmacs-gowl-input-remap--enabled
      (cmacs-gowl-input-remap-enable))
    (cmacs-gowl-input-remap--send name plist))
  name)

;;;###autoload
(defun cmacs-gowl-input-remap-remove (name)
  "Remove remap rule NAME.  Devices only it claimed are released."
  (interactive
   (list (completing-read "Remove remap rule: "
                          (mapcar (lambda (r) (alist-get 'name r))
                                  (cmacs-gowl-input-remap-list))
                          nil t)))
  (setq cmacs-gowl-input-remap--defined
        (assoc-delete-all name cmacs-gowl-input-remap--defined))
  (let ((prefix (concat name "/")))
    (maphash (lambda (key _)
               (when (string-prefix-p prefix key)
                 (remhash key cmacs-gowl-input-remap--functions)))
             cmacs-gowl-input-remap--functions))
  (let ((reply (cmacs-gowl-input-remap--command
                (concat "inputremap-remove " name))))
    (when (called-interactively-p 'interactive)
      (message "Input remap: %s" reply))
    reply))

(defun cmacs-gowl-input-remap-clear ()
  "Remove every rule added at runtime (the config's rules stay)."
  (interactive)
  (setq cmacs-gowl-input-remap--defined nil)
  (clrhash cmacs-gowl-input-remap--functions)
  (cmacs-gowl-input-remap--command "inputremap-clear"))

(defun cmacs-gowl-input-remap-list ()
  "The rules in force, as alists: name, source, mappings, yaml, devices."
  (cmacs-gowl-input-remap--json "inputremap-list"))

(defun cmacs-gowl-input-remap-status ()
  "Show the module's status in the echo area, and return it."
  (interactive)
  (let ((status (cmacs-gowl-input-remap--command "inputremap-status")))
    (when (called-interactively-p 'interactive)
      (message "Input remap: %s" status))
    status))

(defun cmacs-gowl-input-remap--call (rule input)
  "Run the function target of RULE for INPUT.
What a function target's `custom' action evaluates.  An error is
reported and swallowed, as a custom keybind's is."
  (let ((fn (gethash (format "%s/%s" rule input)
                     cmacs-gowl-input-remap--functions)))
    (if (not fn)
        (message "cmacs-gowl-input-remap: no function for %s/%s" rule input)
      (condition-case err
          (let ((arity (func-arity fn)))
            (if (or (eq (cdr arity) 'many) (>= (cdr arity) 2))
                (funcall fn rule input)
              (funcall fn)))
        (error (message "cmacs-gowl-input-remap: %s/%s: %s" rule input
                        (error-message-string err)))))))

;;;; Devices and identify mode

(defun cmacs-gowl-input-remap-list-devices ()
  "Every connected keyboard and pointer, as alists."
  (cmacs-gowl-input-remap--json "inputremap-devices"))

(defun cmacs-gowl-input-remap--match-snippet (device)
  "A `:match' plist naming DEVICE, as text for the kill ring."
  (let ((vp (alist-get 'vendor-product device)))
    (if (and vp (not (equal vp "0000:0000")))
        (format "(:id %S :type %s)" vp (alist-get 'type device))
      (format "(:name %S :type %s)" (alist-get 'name device)
              (alist-get 'type device)))))

(defvar cmacs-gowl-input-remap--identify-timer nil
  "The timer polling for identify mode's result.")

(defun cmacs-gowl-input-remap--identify-poll (deadline)
  "Poll for identify mode's result until DEADLINE (a float time)."
  (let ((reply (ignore-errors
                 (cmacs-gowl-input-remap--command
                  "inputremap-identify-result"))))
    (cond
     ((and reply (string-prefix-p "{" reply))
      (cancel-timer cmacs-gowl-input-remap--identify-timer)
      (setq cmacs-gowl-input-remap--identify-timer nil)
      (let* ((result (json-parse-string reply :object-type 'alist
                                        :null-object nil :false-object nil))
             (device (alist-get 'device result))
             (snippet (cmacs-gowl-input-remap--match-snippet device)))
        (kill-new snippet)
        (message "Input remap: %s on \"%s\" (%s) -- %s copied"
                 (alist-get 'input result) (alist-get 'name device)
                 (alist-get 'vendor-product device) snippet)
        (run-hook-with-args 'cmacs-gowl-input-remap-identified-functions
                            result)))
     ((or (null reply) (equal reply "none") (> (float-time) deadline))
      (cancel-timer cmacs-gowl-input-remap--identify-timer)
      (setq cmacs-gowl-input-remap--identify-timer nil)
      (message "Input remap: nothing was pressed")))))

;;;###autoload
(defun cmacs-gowl-input-remap-identify (&optional seconds)
  "Press a device within SECONDS and learn its identity.
Observes every keyboard and pointer without consuming anything; the
first press reports the device, its vendor:product and the input it
sent, and puts a `:match' plist for it on the kill ring.  SECONDS
defaults to `cmacs-gowl-input-remap-identify-timeout'."
  (interactive "P")
  (let ((secs (if (integerp seconds) seconds
                cmacs-gowl-input-remap-identify-timeout)))
    (unless cmacs-gowl-input-remap--enabled
      (cmacs-gowl-input-remap-enable))
    (cmacs-gowl-input-remap--command (format "inputremap-identify %d" secs))
    (when cmacs-gowl-input-remap--identify-timer
      (cancel-timer cmacs-gowl-input-remap--identify-timer))
    (let ((deadline (+ (float-time) secs 1)))
      (setq cmacs-gowl-input-remap--identify-timer
            (run-with-timer 0.25 0.25
                            #'cmacs-gowl-input-remap--identify-poll
                            deadline)))
    (message "Input remap: press the device within %d seconds..." secs)))

(defvar-keymap cmacs-gowl-input-remap-devices-mode-map
  :doc "Keys in the input devices buffer."
  "i" #'cmacs-gowl-input-remap-identify
  "w" #'cmacs-gowl-input-remap-devices-copy-match
  "RET" #'cmacs-gowl-input-remap-devices-copy-match)

(define-derived-mode cmacs-gowl-input-remap-devices-mode tabulated-list-mode
  "Input-Devices"
  "Every keyboard and pointer gowl knows, and which are claimed.
\\<cmacs-gowl-input-remap-devices-mode-map>
\\[cmacs-gowl-input-remap-devices-copy-match] copies a `:match' plist for
the device at point, \\[cmacs-gowl-input-remap-identify] identifies the
next device pressed, and \\[revert-buffer] refreshes."
  (setq tabulated-list-format
        [("Id" 4 t :right-align t)
         ("Type" 9 t)
         ("Vendor:Product" 15 t)
         ("Sysname" 10 t)
         ("Claimed" 8 t)
         ("Name" 0 t)])
  (setq tabulated-list-sort-key '("Id"))
  (add-hook 'tabulated-list-revert-hook
            #'cmacs-gowl-input-remap--devices-refresh nil t)
  (tabulated-list-init-header))

(defun cmacs-gowl-input-remap--devices-refresh ()
  "Fill the devices buffer from the module."
  (setq tabulated-list-entries
        (mapcar (lambda (d)
                  (list d
                        (vector (number-to-string (alist-get 'id d))
                                (alist-get 'type d)
                                (alist-get 'vendor-product d)
                                (or (alist-get 'sysname d) "-")
                                (if (alist-get 'claimed d) "yes" "")
                                (alist-get 'name d))))
                (cmacs-gowl-input-remap-list-devices))))

(defun cmacs-gowl-input-remap-devices-copy-match ()
  "Copy a `:match' plist for the device at point."
  (interactive)
  (let ((device (tabulated-list-get-id)))
    (unless device
      (user-error "No device on this line"))
    (let ((snippet (cmacs-gowl-input-remap--match-snippet device)))
      (kill-new snippet)
      (message "Copied %s" snippet))))

;;;###autoload
(defun cmacs-gowl-input-remap-devices ()
  "List every keyboard and pointer, with the identity a rule matches on."
  (interactive)
  (unless cmacs-gowl-input-remap--enabled
    (cmacs-gowl-input-remap-enable))
  (with-current-buffer (get-buffer-create "*gowl input devices*")
    (cmacs-gowl-input-remap-devices-mode)
    (cmacs-gowl-input-remap--devices-refresh)
    (tabulated-list-print)
    (pop-to-buffer (current-buffer))))

;;;; Startup

(defun cmacs-gowl-input-remap--on-start ()
  "Install the configured and session rules; called by `cmacs-gowl-mode'.
Does nothing, and loads nothing, when there are none."
  (setq cmacs-gowl-input-remap--enabled nil)
  (dolist (rule cmacs-gowl-input-remap-rules)
    (unless (assoc (car rule) cmacs-gowl-input-remap--defined)
      (push rule cmacs-gowl-input-remap--defined)))
  (when cmacs-gowl-input-remap--defined
    (condition-case err
        (cmacs-gowl-input-remap-enable)
      (error (message "cmacs-gowl-input-remap: %s"
                      (error-message-string err))))))

(provide 'cmacs-gowl-input-remap)

;;; cmacs-gowl-input-remap.el ends here
