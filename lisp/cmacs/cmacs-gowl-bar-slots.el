;;; cmacs-gowl-bar-slots.el --- Bar items Elisp creates and fills  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's bar has SLOTS: bar items whose content is pushed from outside
;; (deps/gowl/docs/bar.org, "Slots").  This file is how Elisp makes one.
;;
;;   (cmacs-gowl-bar-slot-set "mail" :text "3 unread" :role 'peach
;;                            :on-click (lambda (_click) (mu4e)))
;;   (cmacs-gowl-bar-slot-set "mail" :text "4 unread")   ; only the text
;;   (cmacs-gowl-bar-slot-remove "mail")
;;
;; and, for an init file, a slot that keeps itself up to date:
;;
;;   (cmacs-gowl-bar-define-slot clock-in
;;     :region 'left :icon "▶" :role 'accent
;;     :update (lambda () (and (org-clocking-p) org-clock-heading))
;;     :every 30)
;;
;; What is kept here, and why.  Every slot Elisp makes is remembered in
;; `cmacs-gowl-bar-slots--table', for three reasons:
;;
;;  - A push names only what changed, and the rest has to come from
;;    somewhere.
;;  - A click handler is a Lisp function.  It never goes to the
;;    compositor -- nothing a slot carries is run there -- so it stays
;;    here, and a click comes back as the bar module's event
;;    "slot-click ID BUTTON MODIFIERS OUTPUT OWNER" on
;;    `cmacs-gowl-module-event-functions', which runs on Emacs's
;;    thread.  The handler is then called from a timer, not from inside
;;    the event: it may prompt, pop a buffer or signal, and none of
;;    that belongs in the compositor's signal dispatch.
;;  - The compositor forgets.  A slot set before `cmacs-gowl-mode'
;;    started, or before a `gowl-stop' and `gowl-start', is pushed
;;    (again) by `cmacs-gowl-bar-slots-restore'.
;;
;; Every slot is made with the owner tag `cmacs-gowl-bar-slots-owner',
;; and a restore begins by asking the bar to drop everything that tag
;; owns: whatever the bar is showing afterwards is what this table
;; says, and nothing a previous Emacs state left behind.
;;
;; Nothing here signals because the bar is not running, has no slots,
;; or refused a push; those are reported once with `message' and the
;; function returns nil.  Bad ARGUMENTS do signal -- a role that is not
;; a role is a bug in the caller, and better found when it is written.
;;
;; A colour is a bar theme ROLE (`cmacs-gowl-bar-slot-roles'), never a
;; hex value: a slot should follow the palette, like the rest of the
;; bar.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-run-command "cmacs-gowl.c" (line))
(declare-function gowl-bar-slot-set "cmacs-gowl-bar-slots.c" (id fields))
(declare-function gowl-bar-slot-remove "cmacs-gowl-bar-slots.c"
                  (id &optional owner))
(declare-function gowl-bar-slot-clear "cmacs-gowl-bar-slots.c" (owner))
(declare-function gowl-bar-slot-list "cmacs-gowl-bar-slots.c"
                  (&optional owner))

(defvar cmacs-gowl-module-event-functions)

(defgroup cmacs-gowl-bar-slots nil
  "Bar items Elisp creates and fills."
  :group 'cmacs
  :prefix "cmacs-gowl-bar-slot")

(defcustom cmacs-gowl-bar-slots-owner "cmacs"
  "The owner tag every slot made from Elisp carries.
The bar lets only a slot's owner change it, and removes an owner's
slots in one call; `cmacs-gowl-bar-slots-restore' relies on that.
Letters, digits, `_', `.' and `-'."
  :type 'string)

(defcustom cmacs-gowl-bar-slots-max-text 120
  "Longest text, in columns, a slot is given; the rest is cut with an ellipsis.
The bar has its own, larger limit (256 bytes).  This one is about
what fits on a bar next to everything else."
  :type 'natnum)

(defconst cmacs-gowl-bar-slot-roles
  '("base" "mantle" "crust" "surface" "surface-alt" "overlay" "text"
    "subtext" "muted" "accent" "red" "green" "yellow" "blue" "mauve"
    "teal" "peach" "pink" "sapphire" "sky" "lavender" "flamingo"
    "rosewater" "maroon")
  "The bar's theme roles: what a slot's :role may be.
From gowl's docs/bar.org, \"Theming\".")

(defconst cmacs-gowl-bar-slots--keys
  '(:text :icon :role :tooltip :urgency :region :order :bar :output
    :on-click :owner :ttl :update :every)
  "The keys a slot's plist may hold.")

(defvar cmacs-gowl-bar-slots--table (make-hash-table :test #'equal)
  "Every slot Elisp has made: id (a string) -> its plist.
The plist holds the keys of `cmacs-gowl-bar-slots--keys' as given,
plus :timer for a slot with :update and :every.")

(defvar cmacs-gowl-bar-slots--reported (make-hash-table :test #'equal)
  "What has already been said about a slot: id -> the last message.
A push that keeps failing says so once, not on every tick.")

(defvar cmacs-gowl-bar-slots-command-function
  #'cmacs-gowl-bar-slots--command
  "How a slot operation reaches the bar.  Tests rebind it.
Called with (OP &rest ARGS), OP being `set' (ID FIELDS), `remove' (ID
OWNER), `clear' (OWNER) or `list' (OWNER), and returns the bar's reply,
a string, or nil when there is no bar to ask.")

;;;; Reaching the bar

(defun cmacs-gowl-bar-slots--running-p ()
  "Non-nil when a gowl compositor is running in this Emacs."
  (and (fboundp 'gowl-running-p)
       (ignore-errors (gowl-running-p))))

(defun cmacs-gowl-bar-slots--command (op &rest args)
  "Send the slot operation OP with ARGS to the running bar.
Through the `gowl-bar-slot-*' primitives; in an Emacs built before
them, through `gowl-run-command', which reaches the same bar commands
as a line of text.  Returns the reply, or nil with no compositor."
  (when (cmacs-gowl-bar-slots--running-p)
    (pcase op
      ('set
       (pcase-let ((`(,id ,fields) args))
         (cond
          ((fboundp 'gowl-bar-slot-set) (gowl-bar-slot-set id fields))
          ((fboundp 'gowl-run-command)
           ;; One line: `json-serialize' escapes a newline in the text.
           (gowl-run-command
            (concat "bar-slot-set "
                    (json-serialize
                     (cons (cons 'id id)
                           (mapcar (lambda (cell)
                                     (cons (intern (car cell))
                                           (pcase (cdr cell)
                                             ('nil :false)
                                             (value value))))
                                   fields)))))))))
      ('remove
       (pcase-let ((`(,id ,owner) args))
         (cond
          ((fboundp 'gowl-bar-slot-remove) (gowl-bar-slot-remove id owner))
          ((fboundp 'gowl-run-command)
           (gowl-run-command
            (format "bar-slot-remove %s%s" id
                    (if owner (concat " " owner) "")))))))
      ('clear
       (let ((owner (car args)))
         (cond
          ((fboundp 'gowl-bar-slot-clear) (gowl-bar-slot-clear owner))
          ((fboundp 'gowl-run-command)
           (gowl-run-command (format "bar-slot-clear %s" owner))))))
      ('list
       (let ((owner (car args)))
         (cond
          ((fboundp 'gowl-bar-slot-list) (gowl-bar-slot-list owner))
          ((fboundp 'gowl-run-command)
           (gowl-run-command
            (if owner (format "bar-slot-list %s" owner) "bar-slot-list")))))))))

(defun cmacs-gowl-bar-slots--send (id op &rest args)
  "Run the slot operation OP with ARGS, on behalf of the slot ID.
Return the bar's reply when it took it, nil when there is no bar or
it refused.  Never signals.  A refusal is reported once per slot and
reason; a success clears what was reported, so the next failure is
news again."
  (let ((reply (condition-case err
                   (apply cmacs-gowl-bar-slots-command-function op args)
                 (error (format "error: %s" (error-message-string err))))))
    (cond
     ((not (stringp reply)) nil)
     ((string-prefix-p "error" reply)
      (let ((said (string-trim reply)))
        (unless (equal said (gethash id cmacs-gowl-bar-slots--reported))
          (puthash id said cmacs-gowl-bar-slots--reported)
          (message "cmacs-gowl-bar-slots: %s: %s" id said)))
      nil)
     (t
      (remhash id cmacs-gowl-bar-slots--reported)
      reply))))

;;;; What a slot may say

;;;###autoload
(defun cmacs-gowl-bar-slot-id (name)
  "Return NAME, a string or symbol, as a bar slot id.
An id is 1 to 64 of letters, digits, `_', `.' and `-', starting with a
letter, a digit or `_'.  Anything else in NAME becomes a `-', so any
name -- a watch's, a project's -- has a slot id, and the same name
always has the same one."
  (let* ((raw (if (symbolp name) (symbol-name name) (format "%s" name)))
         (id (replace-regexp-in-string "[^A-Za-z0-9_.-]+" "-" raw))
         (id (replace-regexp-in-string "\\`[-.]+" "" id))
         (id (if (> (length id) 64) (substring id 0 64) id))
         (id (replace-regexp-in-string "-+\\'" "" id)))
    (if (string-empty-p id) "slot" id)))

(defun cmacs-gowl-bar-slots--check-id (id)
  "Return ID, a string or symbol, as a string; signal unless it is a slot id."
  (let ((id (if (symbolp id) (symbol-name id) id))
        (case-fold-search nil))
    (unless (and (stringp id)
                 (string-match-p
                  "\\`[A-Za-z0-9_][A-Za-z0-9_.-]\\{0,63\\}\\'" id))
      (error "Not a bar slot id (letters, digits, _ . -): %S" id))
    id))

(defun cmacs-gowl-bar-slots--name (value)
  "VALUE, a symbol or string, as a lower-case string; nil for nil."
  (cond ((null value) nil)
        ((symbolp value) (downcase (symbol-name value)))
        ((stringp value) (downcase value))
        (t (error "Not a name: %S" value))))

(defun cmacs-gowl-bar-slots--one-of (key value choices)
  "VALUE as a name, checked to be one of CHOICES for the slot key KEY."
  (let ((name (cmacs-gowl-bar-slots--name value)))
    (when (and name (not (member name choices)))
      (error "Bar slot %s is one of %s, not %S"
             key (mapconcat #'identity choices ", ") value))
    name))

(defun cmacs-gowl-bar-slots--text (value)
  "VALUE as one line of slot text, cut to `cmacs-gowl-bar-slots-max-text'."
  (let ((text (replace-regexp-in-string
               "[\n\r\t]+" " "
               (cond ((null value) "")
                     ((stringp value) (substring-no-properties value))
                     (t (format "%s" value))))))
    (if (and (> cmacs-gowl-bar-slots-max-text 0)
             (> (string-width text) cmacs-gowl-bar-slots-max-text))
        (truncate-string-to-width text cmacs-gowl-bar-slots-max-text
                                  nil nil t)
      text)))

(defun cmacs-gowl-bar-slots--check (plist)
  "Signal unless PLIST is something a slot can be given.
Checked when it is given, so that a bad role is an error where it was
written rather than a refusal reported from a timer."
  (let ((tail plist))
    (while tail
      (unless (memq (car tail) cmacs-gowl-bar-slots--keys)
        (error "A bar slot has no %S" (car tail)))
      (unless (cdr tail)
        (error "Bar slot key %S has no value" (car tail)))
      (setq tail (cddr tail))))
  (cmacs-gowl-bar-slots--one-of :role (plist-get plist :role)
                                cmacs-gowl-bar-slot-roles)
  (cmacs-gowl-bar-slots--one-of :urgency (plist-get plist :urgency)
                                '("low" "normal" "critical"))
  (cmacs-gowl-bar-slots--one-of :region (plist-get plist :region)
                                '("left" "center" "centre" "right"))
  (cmacs-gowl-bar-slots--one-of :bar (plist-get plist :bar)
                                '("top" "bottom"))
  (dolist (key '(:order :ttl))
    (let ((value (plist-get plist key)))
      (unless (or (null value) (integerp value))
        (error "Bar slot %s is an integer, not %S" key value))))
  (dolist (key '(:on-click :update))
    (let ((value (plist-get plist key)))
      (unless (or (null value) (functionp value))
        (error "Bar slot %s is a function, not %S" key value))))
  (let ((every (plist-get plist :every)))
    (unless (or (null every) (and (numberp every) (> every 0)))
      (error "Bar slot :every is a positive number of seconds, not %S"
             every)))
  plist)

(defun cmacs-gowl-bar-slots--fields (plist)
  "The alist of fields PLIST becomes on its way to the bar.
Every field, every time: the bar ignores what has not changed, and a
slot it has lost is made again by the same push that would have
updated it."
  (let ((region (cmacs-gowl-bar-slots--name (plist-get plist :region))))
    (list (cons "owner" cmacs-gowl-bar-slots-owner)
          (cons "text" (cmacs-gowl-bar-slots--text (plist-get plist :text)))
          (cons "icon" (or (plist-get plist :icon) ""))
          (cons "role" (or (cmacs-gowl-bar-slots--name
                            (plist-get plist :role))
                           ""))
          (cons "tooltip" (let ((tip (plist-get plist :tooltip)))
                            (if tip (substring-no-properties
                                     (format "%s" tip))
                              "")))
          (cons "urgency" (or (cmacs-gowl-bar-slots--name
                               (plist-get plist :urgency))
                              "normal"))
          ;; The handler stays here; the bar is only told to report.
          (cons "click" (and (plist-get plist :on-click) t))
          (cons "bar" (or (cmacs-gowl-bar-slots--name (plist-get plist :bar))
                          "top"))
          (cons "region" (cond ((null region) "right")
                               ((equal region "centre") "center")
                               (t region)))
          (cons "order" (or (plist-get plist :order) 0))
          (cons "output" (or (plist-get plist :output) ""))
          (cons "ttl" (or (plist-get plist :ttl) 0)))))

;;;; The table

(defun cmacs-gowl-bar-slots--merge (old new)
  "OLD, a slot's plist, with every key of NEW put over it."
  (let ((merged (copy-sequence old)))
    (while new
      (setq merged (plist-put merged (car new) (cadr new))
            new (cddr new)))
    merged))

(defun cmacs-gowl-bar-slots--push (id)
  "Push the slot ID as the table has it.  Non-nil when the bar took it."
  (when-let* ((plist (gethash id cmacs-gowl-bar-slots--table)))
    (and (cmacs-gowl-bar-slots--send
          id 'set id (cmacs-gowl-bar-slots--fields plist))
         t)))

;;;###autoload
(defun cmacs-gowl-bar-slot-set (id &rest plist)
  "Create the gowl bar slot ID, or change it, from PLIST.
ID is a string or a symbol: letters, digits, `_', `.' and `-'
\(`cmacs-gowl-bar-slot-id' makes one out of any name).  Only the keys
PLIST names change; the rest of the slot stays as it was.

  :text STRING      what it says.  nil or \"\" shows nothing: a slot
                    with neither text nor icon takes no room.
  :icon STRING      a glyph drawn before the text, in the bar's icon
                    font.
  :role ROLE        a bar theme role for its colour, a symbol or
                    string from `cmacs-gowl-bar-slot-roles' -- `text',
                    `accent', `red', `green', `peach' ...  Never a hex
                    colour.  nil for the urgency's own.
  :tooltip STRING   hover text.
  :urgency LEVEL    `low' (muted), `normal', or `critical' (red, over
                    a wash of it).
  :region REGION    `left', `center' or `right' (the default).
  :order N          where among the region's slots: negative before
                    the region's own widgets, zero and up after them.
  :bar BAR          `top' (the default) or `bottom'.
  :output NAME      the one output to show on (\"eDP-1\"); nil for all.
  :on-click FN      called with one argument when the slot is clicked,
                    a plist (:id ID :button BUTTON :modifiers LIST
                    :output NAME), BUTTON being `left', `right',
                    `middle' or `button-N'.  FN runs in Emacs, from a
                    timer; nothing is run in the compositor.
  :owner SYMBOL     which package this slot is; see
                    `cmacs-gowl-bar-slot-clear'.
  :ttl SECONDS      have the bar remove the slot this long after the
                    last push, should Emacs stop pushing.

The slot is remembered, so it is shown as soon as there is a bar to
show it on and again after the compositor restarts.  Return non-nil
when the bar took it now; nil when no bar is running, or it refused
\(which is reported in the echo area, once).  Signal an error for a
PLIST that could never be right.

To put a slot BETWEEN two particular widgets, write `slot:ID' into the
bar's widget list where you want it; a slot of that id fills it."
  (let* ((id (cmacs-gowl-bar-slots--check-id id))
         (plist (cmacs-gowl-bar-slots--check plist))
         (merged (cmacs-gowl-bar-slots--merge
                  (gethash id cmacs-gowl-bar-slots--table) plist)))
    (puthash id merged cmacs-gowl-bar-slots--table)
    (cmacs-gowl-bar-slots--push id)))

(defun cmacs-gowl-bar-slots--forget (id)
  "Take the slot ID out of the table, stopping its timer."
  (when-let* ((plist (gethash id cmacs-gowl-bar-slots--table)))
    (when (timerp (plist-get plist :timer))
      (cancel-timer (plist-get plist :timer)))
    (remhash id cmacs-gowl-bar-slots--table)
    (remhash id cmacs-gowl-bar-slots--reported)
    t))

;;;###autoload
(defun cmacs-gowl-bar-slot-remove (id)
  "Remove the gowl bar slot ID, a string or symbol.
It is forgotten here and taken off the bar.  Return non-nil if there
was such a slot.  Removing one that does not exist is not an error."
  (let ((id (cmacs-gowl-bar-slots--check-id id)))
    (when (cmacs-gowl-bar-slots--forget id)
      ;; Named with the owner, so that a slot of the same id made by
      ;; something else -- a script on the socket -- is refused rather
      ;; than removed.
      (cmacs-gowl-bar-slots--send id 'remove id cmacs-gowl-bar-slots-owner)
      t)))

;;;###autoload
(defun cmacs-gowl-bar-slot-clear (&optional owner)
  "Remove every bar slot made with :owner OWNER, a symbol.
With OWNER nil, remove every slot Elisp has made -- and ask the bar to
drop anything else carrying `cmacs-gowl-bar-slots-owner', which is
what clears up after an Emacs state that is gone.  Return how many
were forgotten."
  (let ((ids nil))
    (maphash (lambda (id plist)
               (when (or (null owner) (eq owner (plist-get plist :owner)))
                 (push id ids)))
             cmacs-gowl-bar-slots--table)
    (if owner
        (dolist (id ids)
          (cmacs-gowl-bar-slot-remove id))
      (dolist (id ids)
        (cmacs-gowl-bar-slots--forget id))
      (cmacs-gowl-bar-slots--send cmacs-gowl-bar-slots-owner
                                  'clear cmacs-gowl-bar-slots-owner))
    (length ids)))

;;;###autoload
(defun cmacs-gowl-bar-slot-list (&optional live)
  "Return the bar slots Elisp has made, as a list of (ID . PLIST), by id.
With LIVE non-nil, ask the bar instead and return what it is showing
for `cmacs-gowl-bar-slots-owner': a list of alists with the keys `id',
`owner', `bar', `region', `order', `output', `text', `icon', `role',
`tooltip', `urgency', `click', `ttl' and `placed'; nil with no bar."
  (if live
      (when-let* ((json (cmacs-gowl-bar-slots--send
                         cmacs-gowl-bar-slots-owner
                         'list cmacs-gowl-bar-slots-owner)))
        (condition-case nil
            (json-parse-string json :object-type 'alist :array-type 'list
                               :false-object nil)
          (error nil)))
    (let (slots)
      (maphash (lambda (id plist) (push (cons id plist) slots))
               cmacs-gowl-bar-slots--table)
      (sort slots (lambda (a b) (string< (car a) (car b)))))))

;;;; Slots that keep themselves up to date

(defun cmacs-gowl-bar-slots--refresh (id)
  "Call the slot ID's :update function and push what it returns.
A string is the new text, a plist is merged in, and nil shows nothing.
An error in the function is reported once and leaves the slot as it
was: this runs from a timer."
  (when-let* ((plist (gethash id cmacs-gowl-bar-slots--table))
              (update (plist-get plist :update)))
    (condition-case err
        (let ((value (funcall update)))
          (apply #'cmacs-gowl-bar-slot-set id
                 (cond ((stringp value) (list :text value))
                       ((null value) (list :text ""))
                       ((and (consp value) (keywordp (car value))) value)
                       (t (list :text (format "%s" value))))))
      (error
       (let ((said (format "update failed: %s" (error-message-string err))))
         (unless (equal said (gethash id cmacs-gowl-bar-slots--reported))
           (puthash id said cmacs-gowl-bar-slots--reported)
           (message "cmacs-gowl-bar-slots: %s: %s" id said)))))))

(defun cmacs-gowl-bar-slots--define (id &rest plist)
  "Define the slot ID from PLIST.
The function behind `cmacs-gowl-bar-define-slot'."
  (let* ((id (cmacs-gowl-bar-slots--check-id id))
         (old (gethash id cmacs-gowl-bar-slots--table)))
    (cmacs-gowl-bar-slots--check plist)
    ;; A definition REPLACES: evaluating the form again after editing
    ;; it must not leave a key the new form no longer has.
    (when (timerp (plist-get old :timer))
      (cancel-timer (plist-get old :timer)))
    (puthash id (copy-sequence plist) cmacs-gowl-bar-slots--table)
    (when (and (plist-get plist :update) (plist-get plist :every))
      (puthash id
               (plist-put (gethash id cmacs-gowl-bar-slots--table) :timer
                          (run-at-time (plist-get plist :every)
                                       (plist-get plist :every)
                                       #'cmacs-gowl-bar-slots--refresh id))
               cmacs-gowl-bar-slots--table))
    (if (plist-get plist :update)
        (cmacs-gowl-bar-slots--refresh id)
      (cmacs-gowl-bar-slots--push id))
    id))

;;;###autoload
(defmacro cmacs-gowl-bar-define-slot (id &rest plist)
  "Define the gowl bar slot ID (an unquoted symbol or a string) from PLIST.
For an init file.  PLIST takes every key of `cmacs-gowl-bar-slot-set',
and two more:

  :update FN      a function of no arguments giving what the slot
                  shows: a string (its text), nil (nothing), or a plist
                  of slot keys to change (:text, :role, :urgency ...).
  :every SECONDS  call FN again this often.  Without it FN runs once,
                  now, and again whenever you call
                  `cmacs-gowl-bar-slot-refresh'.

FN runs from a timer in Emacs, under `cmacs --gowl' on the thread the
whole desktop waits on: it must return at once.  Read state Emacs
already has; never run a process, read the network or prompt.  For
something that has to be computed elsewhere, set the slot from that
computation's callback with `cmacs-gowl-bar-slot-set' instead -- which
is what an LQL watch's :bar sink does.

Evaluating the form again replaces the slot.  It works before the
compositor has started: the slot is remembered and shown when the bar
is.

  (cmacs-gowl-bar-define-slot clock-in
    :region \\='left :role \\='accent
    :update (lambda ()
              (and (bound-and-true-p org-clock-current-task)
                   (substring-no-properties org-clock-current-task)))
    :every 30
    :on-click (lambda (_click) (org-clock-goto)))"
  (declare (indent 1))
  `(cmacs-gowl-bar-slots--define ',(if (symbolp id) (symbol-name id) id)
                                 ,@plist))

;;;###autoload
(defun cmacs-gowl-bar-slot-refresh (&optional id)
  "Run the :update function of the slot ID now, or of every slot that has one."
  (interactive)
  (if id
      (cmacs-gowl-bar-slots--refresh (cmacs-gowl-bar-slots--check-id id))
    (maphash (lambda (slot plist)
               (when (plist-get plist :update)
                 (cmacs-gowl-bar-slots--refresh slot)))
             ;; A refresh rewrites the table it would be walking.
             (copy-hash-table cmacs-gowl-bar-slots--table))))

;;;; Clicks

(defun cmacs-gowl-bar-slots--parse-click (text)
  "The click the bar's event TEXT reports, as a plist, or nil.
TEXT is \"slot-click ID BUTTON MODIFIERS OUTPUT OWNER\"; a missing
modifier, output or owner is written `-'.  The result has :id, :button
\(a symbol), :modifiers (a list of symbols), :output (a string or nil)
and :owner (a string or nil)."
  (let ((words (and (stringp text) (split-string text " " t))))
    (when (and (equal (car words) "slot-click") (= (length words) 6))
      (pcase-let ((`(,_ ,id ,button ,mods ,output ,owner) words))
        (list :id id
              :button (intern button)
              :modifiers (unless (equal mods "-")
                           (mapcar #'intern (split-string mods "+" t)))
              :output (unless (equal output "-") output)
              :owner (unless (equal owner "-") owner))))))

(defun cmacs-gowl-bar-slots--call-handler (handler click)
  "Call HANDLER with CLICK, reporting an error instead of signalling it."
  (condition-case err
      (funcall handler click)
    (error (message "cmacs-gowl-bar-slots: %s: click handler failed: %s"
                    (plist-get click :id) (error-message-string err)))))

(defun cmacs-gowl-bar-slots--on-module-event (module text)
  "Dispatch a slot click the gowl MODULE reported as TEXT.
On `cmacs-gowl-module-event-functions', and so inside the compositor's
signal dispatch on Emacs's thread: it parses, looks the handler up and
leaves.  The handler runs from a timer, where prompting, popping a
buffer and signalling are all ordinary things to do.  A click on a
slot that is not ours -- another owner's, or one this table does not
have -- is nobody's here."
  (when (equal module "bar")
    (when-let* ((click (cmacs-gowl-bar-slots--parse-click text))
                ((equal (plist-get click :owner) cmacs-gowl-bar-slots-owner))
                (plist (gethash (plist-get click :id)
                                cmacs-gowl-bar-slots--table))
                (handler (plist-get plist :on-click)))
      (run-at-time 0 nil #'cmacs-gowl-bar-slots--call-handler handler
                   ;; The owner tag is the bar's business, not the
                   ;; handler's.
                   (list :id (plist-get click :id)
                         :button (plist-get click :button)
                         :modifiers (plist-get click :modifiers)
                         :output (plist-get click :output))))))

(add-hook 'cmacs-gowl-module-event-functions
          #'cmacs-gowl-bar-slots--on-module-event)

;;;; Starting and stopping

;;;###autoload
(defun cmacs-gowl-bar-slots-restore ()
  "Show every slot Elisp has made on the bar that is running now.
For `cmacs-gowl-mode' to call once its bar is up, and safe to call at
any other time.  First the bar is asked to drop whatever carries
`cmacs-gowl-bar-slots-owner' -- left by a table that has since changed
-- then every remembered slot is pushed.  Return how many the bar
took; nil with no compositor running."
  (when (cmacs-gowl-bar-slots--running-p)
    (clrhash cmacs-gowl-bar-slots--reported)
    (cmacs-gowl-bar-slots--send cmacs-gowl-bar-slots-owner
                                'clear cmacs-gowl-bar-slots-owner)
    (let ((taken 0))
      (dolist (id (mapcar #'car (cmacs-gowl-bar-slot-list)))
        (when (cmacs-gowl-bar-slots--push id)
          (setq taken (1+ taken))))
      taken)))

(defun cmacs-gowl-bar-slots--on-start ()
  "Put the remembered slots on the bar of a compositor that just started.
Called by `cmacs-gowl-mode' when the compositor (re)starts, after its
bar is up.  Never signals: this runs in the compositor's startup, where
an error would cost everything that comes after it."
  (condition-case err
      (cmacs-gowl-bar-slots-restore)
    (error (message "cmacs-gowl-bar-slots: could not restore: %s"
                    (error-message-string err))
           nil)))

(provide 'cmacs-gowl-bar-slots)

;;; cmacs-gowl-bar-slots.el ends here
