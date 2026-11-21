;;; cmacs-journal-filter.el --- Privacy filters for the activity journal  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The privacy core of `cmacs-journal'.  Every event the journal sees
;; passes through `cmacs-journal-filter-apply' BEFORE it is kept
;; anywhere -- before the open span, before the in-memory queue, and so
;; before the files, the LQL source and any agent.  An excluded event
;; never existed as far as the rest of the journal can tell.
;;
;; A rule is a MATCH plus ACTIONS:
;;
;;   match    field -> regexp pairs over any event field; all must match.
;;            In Elisp the match may also be a predicate function.
;;   exclude  drop the whole event.  The open span closes and the time
;;            becomes an untracked gap.
;;   drop     a list of fields to blank.
;;   replace  a list of (field regexp with): sanitise part of a field.
;;   hash     a list of fields replaced by a short keyed hash, so
;;            durations still aggregate without revealing the text.
;;
;; Rules come from three places, merged into one set:
;;
;;   `cmacs-journal-default-filters'  shipped defaults (password
;;       managers, private browser windows, authentication prompts).
;;   `cmacs-journal-filters'          the user's Elisp config.
;;   `cmacs-journal-filter-files'     YAML files, meant to live OUTSIDE a
;;       tracked dotfiles repository: the exclusion rules themselves say
;;       what a person does not want recorded, which is the same as
;;       saying what they do.
;;
;; Three properties this file exists to keep:
;;
;;   * Matching is done against the ORIGINAL event for every rule, then
;;     the actions are applied.  A `drop' in one rule can therefore never
;;     hide the text another rule's `exclude' was waiting for.
;;
;;   * Nothing records which rule matched.  Not in the event, not in a
;;     log, not in a message.  A trace that "rule 4 fired at 14:02" is
;;     the thing the rule was written to keep out.
;;
;;   * It FAILS CLOSED.  A listed YAML file that exists but cannot be
;;     read, cannot be parsed, or holds a key, action, field or regexp
;;     this file does not understand leaves the journal with NO usable
;;     rule set: `cmacs-journal-filter-ready-p' is nil and
;;     `cmacs-journal-filter-apply' drops every event.  A missing file is
;;     fine.  A typo in an exclusion rule must not silently become
;;     "record everything".
;;
;; Regexps in Elisp rules are Emacs regexps.  Regexps in YAML files are
;; written the way they are everywhere else (`\d', `(a|b)', `{6,}') and
;; translated; a construct that cannot be translated (lookaround, `\p')
;; is an error, which fails closed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-yaml-parse-file "cmacs-yaml.c" (file))
(declare-function file-notify-add-watch "filenotify" (file flags callback))
(declare-function file-notify-rm-watch "filenotify" (descriptor))

(defgroup cmacs-journal-filter nil
  "Privacy filters for the cmacs activity journal."
  :group 'cmacs-journal
  :prefix "cmacs-journal-filter")

(defconst cmacs-journal-filter-fields
  '(:kind :app :title :pid :tags :monitor :buffer :file :mode :project
    :url :detail :text)
  "Event fields a rule may match on.

`:text' is not a journal field: the journal records no text and never
builds an event that has one, so a rule on it changes nothing the
journal keeps.  It is the field of the free-text event
`cmacs-journal-filter-apply-text' builds -- a clipboard entry, the text
read off the screen, a buffer inlined into a prompt -- which is how the
same rule set serves `cmacs-redact'.")

(defconst cmacs-journal-filter-action-fields
  '(:app :title :pid :tags :monitor :buffer :file :mode :project :url
    :detail :text)
  "Event fields `drop', `replace' and `hash' may change.
The kind and the times are not among them: a rule that wants those gone
wants `exclude'.")

(defcustom cmacs-journal-default-filters
  '(;; Password managers and keyrings.  The window title of one of
    ;; these is routinely the name of the account being looked up.
    (:match ((:app . "keepass\\|bitwarden\\|1password\\|enpass\\|lastpass\\|proton[-.]?pass\\|gopass\\|qtpass\\|seahorse\\|org\\.gnome\\.\\(?:World\\.\\)?Secrets\\|gnome-keyring\\|kwallet"))
     :exclude t)
    ;; Authentication and passphrase prompts.
    (:match ((:app . "polkit\\|pinentry\\|gcr-prompter\\|ssh-askpass\\|askpass"))
     :exclude t)
    (:match ((:title . "\\`\\(?:Authentication Required\\|Unlock Keyring\\|Unlock Login Keyring\\)"))
     :exclude t)
    ;; Private / incognito browser windows, which say so in the title.
    (:match ((:title . "Private Browsing\\|(Private)\\|InPrivate\\|Incognito\\|Private Window"))
     :exclude t)
    (:match ((:app . "tor-?browser")) :exclude t)
    ;; gsurf's throw-away containers: the journal marks a URL browsed in
    ;; one with the detail \"container:temporary\".
    (:match ((:kind . "\\`url\\'") (:detail . "\\`container:temporary")) :exclude t)
    ;; Emacs's own secrets.
    (:match ((:file . "\\.gpg\\'\\|\\.authinfo\\|/\\.password-store/\\|\\.bashrc-secrets\\|/\\.ssh/"))
     :exclude t))
  "Filter rules the journal ships with.
Same shape as `cmacs-journal-filters', applied together with it and with
the YAML files.  Set this to nil to drop the shipped rules.  After
changing it, run `cmacs-journal-filters-reload'."
  :type '(repeat sexp)
  :group 'cmacs-journal-filter)

(defcustom cmacs-journal-filters nil
  "The user's journal filter rules, in Elisp.

A list of rules, each a plist:

  :match    an alist of (FIELD . REGEXP), all of which must match, or a
            function called with the event plist that returns non-nil
            for a match.  FIELD is one of `cmacs-journal-filter-fields'
            (a keyword, a symbol or a string).
  :exclude  non-nil drops the whole event.
  :drop     a list of fields to blank.
  :replace  a list of (FIELD REGEXP WITH): each match of REGEXP in FIELD
            becomes WITH (`\\N' refers to a group).
  :hash     a list of fields to replace by a short keyed hash.

For example:

  \\='((:match ((:app . \"^org\\\\.keepassxc\")) :exclude t)
    (:match ((:url . \"bank\")) :drop (:url :title))
    (:match ((:title . \"Invoice\"))
     :replace ((:title \"[0-9]\\\\{6,\\\\}\" \"***\")) :hash (:file)))

These are Emacs regexps.  An invalid rule leaves the journal with no
usable rule set, and it records nothing until the rule is fixed -- see
`cmacs-journal-filter-ready-p'.  After changing this, run
`cmacs-journal-filters-reload'.

Anything here is in your Emacs configuration, which is often a tracked
repository.  Rules that would themselves give something away belong in
`cmacs-journal-filter-files' instead."
  :type '(repeat sexp)
  :group 'cmacs-journal-filter)

(defcustom cmacs-journal-filter-files '("~/.config/cmacs/journal-filters.yaml")
  "YAML files of journal filter rules.

Each holds the same rule set as `cmacs-journal-filters':

  filters:
    - match: {app: \\='^org\\.keepassxc\\='}
      exclude: true
    - match: {url: \\='bank\\='}
      drop: [url, title]
    - match: {title: \\='Invoice\\='}
      replace: [{field: title, regexp: \\='\\d{6,}\\=', with: \\='***\\='}]
      hash: [file]

These files exist so the rules can live OUTSIDE a tracked dotfiles
repository: a list of what must not be recorded is itself a record.

A file that does not exist is skipped.  A file that exists and cannot be
parsed, or that holds an unknown key, action or field, makes the journal
refuse to record until it is fixed.  The files are re-read when they
change."
  :type '(repeat file)
  :group 'cmacs-journal-filter)

(defcustom cmacs-journal-filter-case-fold t
  "Non-nil means filter regexps ignore case.
The default is t because a rule that matches too much loses a title, and
a rule that matches too little records one."
  :type 'boolean
  :group 'cmacs-journal-filter)

;;;; State

(defvar cmacs-journal-filter--rules nil
  "The compiled rule set, or nil.  Meaningful only when ready.")

(defvar cmacs-journal-filter--loaded nil
  "Non-nil once a rule set has been loaded successfully.")

(defvar cmacs-journal-filter--error nil
  "Why the rule set is unusable (a string), or nil.")

(defvar cmacs-journal-filter--signature nil
  "What the filter files looked like at the last (re)load.")

(defvar cmacs-journal-filter--watches nil
  "File-notify descriptors watching the filter files' directories.")

(defvar cmacs-journal-filter--reload-timer nil
  "Debounce timer for a reload asked for by a file notification.")

(defvar cmacs-journal-filter-hash-key nil
  "The per-install secret `hash' actions are keyed with, a string.
Set by `cmacs-journal' from a file beside the journal.  With no key a
hashed field is blanked instead, never written in the clear.")

(defvar cmacs-journal-filter-changed-functions nil
  "Functions run with t or nil after the rule set is (re)loaded.
The argument is non-nil when the rules are usable.  `cmacs-journal'
pauses on nil and resumes on t.")

(defun cmacs-journal-filter-ready-p ()
  "Non-nil when there is a rule set the journal may record under."
  (and cmacs-journal-filter--loaded (null cmacs-journal-filter--error)))

(defun cmacs-journal-filter-error ()
  "Why the journal's rule set is unusable (a string), or nil."
  cmacs-journal-filter--error)

;;;; Compiling rules

(defun cmacs-journal-filter--field (name allowed where)
  "The field keyword NAME means, which must be in ALLOWED.
NAME is a keyword, a symbol or a string.  WHERE names the rule for the
error."
  (let* ((s (cond ((keywordp name) (substring (symbol-name name) 1))
                  ((symbolp name) (symbol-name name))
                  ((stringp name) name)
                  (t (error "%s: a field name must be a symbol or a string"
                            where))))
         (s (downcase (string-replace "_" "-" s)))
         (s (if (member s '("app-id" "appid" "class")) "app" s))
         (key (intern (concat ":" s))))
    (unless (memq key allowed)
      (error "%s: unknown field `%s'" where s))
    key))

(defun cmacs-journal-filter--check-regexp (regexp field where)
  "Signal unless REGEXP is a valid Emacs regexp.
FIELD and WHERE name it for the error -- the regexp's own text is left
out, because a warning buffer is not where an exclusion rule belongs."
  (unless (stringp regexp)
    (error "%s: the regexp for `%s' must be a string" where
           (substring (symbol-name field) 1)))
  (condition-case nil
      (progn (string-match-p regexp "") regexp)
    (error (error "%s: invalid regexp for `%s'" where
                  (substring (symbol-name field) 1)))))

(defun cmacs-journal-filter--pcre-class (re i)
  "Translate the bracket expression of RE starting at index I.
Return (EMACS-TEXT . NEXT-INDEX)."
  (let ((n (length re)) (j (1+ i))
        (neg nil) (rbracket nil) (caret nil) (dash nil) (body nil)
        (done nil))
    (when (and (< j n) (eq (aref re j) ?^)) (setq neg t j (1+ j)))
    ;; A `]' straight after the opening is a literal.
    (when (and (< j n) (eq (aref re j) ?\])) (setq rbracket t j (1+ j)))
    (while (and (not done) (< j n))
      (let ((c (aref re j)))
        (cond
         ((eq c ?\]) (setq done t j (1+ j)))
         ;; A POSIX class, [:alpha:], passes through whole.
         ((and (eq c ?\[) (< (1+ j) n) (eq (aref re (1+ j)) ?:))
          (let ((end (string-search ":]" re (+ j 2))))
            (unless end (error "unterminated [: :] class"))
            (push (substring re j (+ end 2)) body)
            (setq j (+ end 2))))
         ((eq c ?\\)
          (when (>= (1+ j) n) (error "trailing backslash"))
          (let ((d (aref re (1+ j))))
            (pcase d
              (?d (push "0-9" body))
              (?s (push "[:space:]" body))
              (?w (push "[:alnum:]_" body))
              (?n (push "\n" body))
              (?t (push "\t" body))
              (?r (push "\r" body))
              (?\] (setq rbracket t))
              (?^ (setq caret t))
              (?- (setq dash t))
              ((guard (or (and (>= d ?a) (<= d ?z)) (and (>= d ?A) (<= d ?Z))
                          (and (>= d ?0) (<= d ?9))))
               (error "unsupported escape \\%c in a bracket expression" d))
              (_ (push (string d) body))))
          (setq j (+ j 2)))
         (t (push (string c) body) (setq j (1+ j))))))
    (unless done (error "unterminated bracket expression"))
    ;; Emacs has no escapes inside brackets, so the awkward characters
    ;; go where they are literal: `]' first, `^' not first, `-' last.
    (let ((text (concat (and rbracket "]")
                        (apply #'concat (nreverse body))
                        (and caret "^")
                        (and dash "-"))))
      (when (and (not neg) (string-prefix-p "^" text))
        ;; A lone literal caret: Emacs would read "[^" as a negation.
        (setq text (concat (substring text 1) "^")))
      (when (string-empty-p text) (error "empty bracket expression"))
      (cons (concat "[" (and neg "^") text "]") j))))

(defun cmacs-journal-filter--pcre-to-emacs (re)
  "Translate the Perl-style regexp RE, as written in a YAML file.

Handles what filter rules use: groups and alternation without
backslashes, `{N,M}', `\\d \\s \\w' and their complements, anchors,
`(?:...)' and a leading `(?i)'.  Signals an error for a construct with no
Emacs equivalent (lookaround, named groups, `\\p{...}'); the caller turns
that into a refusal to record, which is the point -- a rule that silently
matched something else would be worse than no journal."
  (let ((i 0) (n (length re)) (out nil))
    (when (string-prefix-p "(?i)" re) (setq i 4))
    (while (< i n)
      (let ((c (aref re i)))
        (cond
         ((eq c ?\\)
          (when (>= (1+ i) n) (error "trailing backslash"))
          (let ((d (aref re (1+ i))))
            (push (pcase d
                    (?d "[0-9]") (?D "[^0-9]")
                    (?s "[[:space:]]") (?S "[^[:space:]]")
                    (?w "[[:alnum:]_]") (?W "[^[:alnum:]_]")
                    (?b "\\b") (?B "\\B")
                    (?n "\n") (?t "\t") (?r "\r")
                    (?A "\\`") ((or ?z ?Z) "\\'")
                    ((guard (and (>= d ?1) (<= d ?9))) (string ?\\ d))
                    ((guard (or (and (>= d ?a) (<= d ?z))
                                (and (>= d ?A) (<= d ?Z))
                                (eq d ?0)))
                     (error "unsupported escape \\%c" d))
                    (_ (regexp-quote (string d))))
                  out))
          (setq i (+ i 2)))
         ((eq c ?\[)
          (let ((class (cmacs-journal-filter--pcre-class re i)))
            (push (car class) out)
            (setq i (cdr class))))
         ((eq c ?\()
          (cond
           ((and (< (+ i 2) n) (eq (aref re (1+ i)) ??)
                 (eq (aref re (+ i 2)) ?:))
            (push "\\(?:" out) (setq i (+ i 3)))
           ((and (< (1+ i) n) (eq (aref re (1+ i)) ??))
            (error "unsupported group (?%c"
                   (if (< (+ i 2) n) (aref re (+ i 2)) ?\s)))
           (t (push "\\(" out) (setq i (1+ i)))))
         ((eq c ?\)) (push "\\)" out) (setq i (1+ i)))
         ((eq c ?|) (push "\\|" out) (setq i (1+ i)))
         ((eq c ?{) (push "\\{" out) (setq i (1+ i)))
         ((eq c ?}) (push "\\}" out) (setq i (1+ i)))
         (t (push (string c) out) (setq i (1+ i))))))
    (apply #'concat (nreverse out))))

(defun cmacs-journal-filter--regexp (regexp field where pcre)
  "REGEXP for FIELD as a checked Emacs regexp.  PCRE means translate it."
  (unless (stringp regexp)
    (error "%s: the regexp for `%s' must be a string" where
           (substring (symbol-name field) 1)))
  (cmacs-journal-filter--check-regexp
   (if pcre
       (condition-case err
           (cmacs-journal-filter--pcre-to-emacs regexp)
         (error (error "%s: regexp for `%s': %s" where
                       (substring (symbol-name field) 1)
                       (error-message-string err))))
     regexp)
   field where))

(defun cmacs-journal-filter--fields (list where)
  "LIST of field names as action field keywords."
  (unless (listp list)
    (error "%s: expected a list of fields" where))
  (mapcar (lambda (f)
            (cmacs-journal-filter--field
             f cmacs-journal-filter-action-fields where))
          list))

(defun cmacs-journal-filter--finish (rule where)
  "Check the compiled RULE is complete and return it."
  (unless (or (plist-get rule :match) (plist-get rule :predicate))
    (error "%s: a rule needs a non-empty match" where))
  (unless (or (plist-get rule :exclude) (plist-get rule :drop)
              (plist-get rule :replace) (plist-get rule :hash))
    (error "%s: a rule needs an action (exclude, drop, replace or hash)"
           where))
  rule)

(defun cmacs-journal-filter--compile-elisp (rule where)
  "Compile the Elisp RULE (a plist).  WHERE names it for errors."
  (unless (and (listp rule) (keywordp (car-safe rule)))
    (error "%s: a rule must be a plist" where))
  (let (out)
    (cl-loop
     for (key value) on rule by #'cddr do
     (pcase key
       (:match
        (cond
         ((functionp value) (setq out (plist-put out :predicate value)))
         ((listp value)
          (setq out
                (plist-put
                 out :match
                 (mapcar
                  (lambda (pair)
                    (unless (consp pair)
                      (error "%s: :match wants (FIELD . REGEXP) pairs" where))
                    (let ((f (cmacs-journal-filter--field
                              (car pair) cmacs-journal-filter-fields where)))
                      (cons f (cmacs-journal-filter--regexp
                               (cdr pair) f where nil))))
                  value))))
         (t (error "%s: :match must be an alist or a function" where))))
       (:exclude (setq out (plist-put out :exclude (and value t))))
       (:drop (setq out (plist-put out :drop
                                   (cmacs-journal-filter--fields value where))))
       (:hash (setq out (plist-put out :hash
                                   (cmacs-journal-filter--fields value where))))
       (:replace
        (setq out
              (plist-put
               out :replace
               (mapcar
                (lambda (r)
                  (unless (and (listp r) (= (length r) 3) (stringp (nth 2 r)))
                    (error "%s: :replace wants (FIELD REGEXP WITH) lists" where))
                  (let ((f (cmacs-journal-filter--field
                            (car r) cmacs-journal-filter-action-fields where)))
                    (list f (cmacs-journal-filter--regexp (nth 1 r) f where nil)
                          (nth 2 r))))
                value))))
       (_ (error "%s: unknown key `%s'" where key))))
    (cmacs-journal-filter--finish out where)))

(defun cmacs-journal-filter--yaml-bool (value key where)
  "VALUE of the YAML boolean KEY as t or nil."
  (cond ((memq value '(t)) t)
        ((memq value '(nil :false)) nil)
        ((and (stringp value)
              (member (downcase value) '("true" "yes" "on")))
         t)
        ((and (stringp value)
              (member (downcase value) '("false" "no" "off")))
         nil)
        (t (error "%s: `%s' must be true or false" where key))))

(defun cmacs-journal-filter--compile-yaml (rule where)
  "Compile RULE, one entry of a YAML file's `filters' list as an alist."
  (unless (and (listp rule) (consp (car-safe rule)))
    (error "%s: a rule must be a mapping" where))
  (let (out)
    (pcase-dolist (`(,key . ,value) rule)
      (pcase key
        ('match
         (unless (and (listp value) value (consp (car value)))
           (error "%s: `match' must be a non-empty mapping of field: regexp"
                  where))
         (setq out
               (plist-put
                out :match
                (mapcar (lambda (pair)
                          (let ((f (cmacs-journal-filter--field
                                    (car pair) cmacs-journal-filter-fields
                                    where)))
                            (cons f (cmacs-journal-filter--regexp
                                     (cdr pair) f where t))))
                        value))))
        ('exclude
         (setq out (plist-put out :exclude
                              (cmacs-journal-filter--yaml-bool
                               value "exclude" where))))
        ('drop (setq out (plist-put
                          out :drop
                          (cmacs-journal-filter--fields value where))))
        ('hash (setq out (plist-put
                          out :hash
                          (cmacs-journal-filter--fields value where))))
        ('replace
         (unless (listp value)
           (error "%s: `replace' must be a list" where))
         (setq out
               (plist-put
                out :replace
                (mapcar
                 (lambda (r)
                   (unless (and (listp r) (consp (car-safe r)))
                     (error "%s: a `replace' entry must be a mapping" where))
                   (pcase-dolist (`(,k . ,_) r)
                     (unless (memq k '(field regexp with))
                       (error "%s: unknown key `%s' in `replace'" where k)))
                   (let* ((f (cmacs-journal-filter--field
                              (or (alist-get 'field r)
                                  (error "%s: `replace' needs `field'" where))
                              cmacs-journal-filter-action-fields where))
                          (with (alist-get 'with r)))
                     (unless (alist-get 'regexp r)
                       (error "%s: `replace' needs `regexp'" where))
                     (unless (or (null with) (stringp with) (numberp with))
                       (error "%s: `with' must be a string" where))
                     (list f
                           (cmacs-journal-filter--regexp
                            (alist-get 'regexp r) f where t)
                           (if with (format "%s" with) ""))))
                 value))))
        (_ (error "%s: unknown key `%s'" where key))))
    (cmacs-journal-filter--finish out where)))

(defun cmacs-journal-filter--rules-from-elisp (rules name)
  "Compile the Elisp rule list RULES; NAME is the variable they came from."
  (unless (listp rules) (error "%s must be a list of rules" name))
  (let ((i 0))
    (mapcar (lambda (rule)
              (setq i (1+ i))
              (cmacs-journal-filter--compile-elisp
               rule (format "%s, rule %d" name i)))
            rules)))

(defun cmacs-journal-filter--rules-from-yaml-data (data name)
  "Compile DATA, a parsed YAML document (an alist); NAME is its file.
DATA is what `json-parse-string' makes of the document with alists for
objects and lists for arrays.  An empty document is no rules."
  (cond
   ((memq data '(nil :null)) nil)
   ((not (and (listp data) (consp (car-safe data))))
    (error "%s: the document must be a mapping with a `filters' list" name))
   (t
    (pcase-dolist (`(,key . ,_) data)
      (unless (eq key 'filters)
        (error "%s: unknown top-level key `%s'" name key)))
    (let ((rules (alist-get 'filters data)) (i 0))
      (unless (listp rules)
        (error "%s: `filters' must be a list" name))
      (mapcar (lambda (rule)
                (setq i (1+ i))
                (cmacs-journal-filter--compile-yaml
                 rule (format "%s, rule %d" name i)))
              rules)))))

(defun cmacs-journal-filter--read-yaml (file)
  "Parse the YAML FILE into the alist the rule compiler takes.
Signals when this cmacs has no YAML reader: a file that is present and
cannot be read is a failure, never an empty rule set."
  (unless (fboundp 'cmacs-yaml-parse-file)
    (error "%s exists, but this cmacs cannot read YAML (no `cmacs-yaml-parse-file')"
           (abbreviate-file-name file)))
  (json-parse-string (cmacs-yaml-parse-file file)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object :false))

(defun cmacs-journal-filter--rules-from-file (file)
  "The compiled rules of the YAML FILE, or nil when it does not exist."
  (let ((path (expand-file-name file)))
    (when (file-remote-p path)
      (error "%s: a filter file must be local" file))
    (when (file-exists-p path)
      (unless (file-readable-p path)
        (error "%s exists but cannot be read" (abbreviate-file-name path)))
      (cmacs-journal-filter--rules-from-yaml-data
       (cmacs-journal-filter--read-yaml path)
       (abbreviate-file-name path)))))

;;;; Loading, watching

(defun cmacs-journal-filter--file-signature ()
  "What the filter files look like now: existence, mtime and size."
  (mapcar (lambda (file)
            (let* ((path (expand-file-name file))
                   (attrs (and (not (file-remote-p path))
                               (file-attributes path))))
              (list path
                    (and attrs (file-attribute-modification-time attrs))
                    (and attrs (file-attribute-size attrs)))))
          cmacs-journal-filter-files))

(defun cmacs-journal-filter--load ()
  "Compile every rule source and return the rule set.  Signals on error."
  (append
   (cmacs-journal-filter--rules-from-elisp
    cmacs-journal-default-filters "cmacs-journal-default-filters")
   (cmacs-journal-filter--rules-from-elisp
    cmacs-journal-filters "cmacs-journal-filters")
   (cl-loop for file in cmacs-journal-filter-files
            append (cmacs-journal-filter--rules-from-file file))))

;;;###autoload
(defun cmacs-journal-filters-reload ()
  "Re-read the journal's filter rules from Elisp and the YAML files.
Return non-nil when the rule set is usable.  When it is not -- a file
that does not parse, an unknown key, an invalid regexp -- the journal
stops recording and a warning says which file and why."
  (interactive)
  (setq cmacs-journal-filter--signature
        (cmacs-journal-filter--file-signature))
  (condition-case err
      (setq cmacs-journal-filter--rules (cmacs-journal-filter--load)
            cmacs-journal-filter--loaded t
            cmacs-journal-filter--error nil)
    (error
     (setq cmacs-journal-filter--rules nil
           cmacs-journal-filter--error (error-message-string err))
     (display-warning
      'cmacs-journal
      (format "The journal's filters could not be loaded, so nothing is being recorded.\n%s\nFix it and run M-x cmacs-journal-filters-reload."
              cmacs-journal-filter--error)
      :error)))
  (let ((ok (cmacs-journal-filter-ready-p)))
    (run-hook-with-args 'cmacs-journal-filter-changed-functions ok)
    (when (called-interactively-p 'interactive)
      (message (if ok "cmacs-journal: %d filter rules loaded"
                 "cmacs-journal: filters NOT loaded; recording is stopped")
               (length cmacs-journal-filter--rules)))
    ok))

(defun cmacs-journal-filter-check ()
  "Reload the rules if a filter file changed since the last load.
The fallback for when file notification is unavailable or missed an
edit; `cmacs-journal' calls it from its flush timer."
  (unless (equal cmacs-journal-filter--signature
                 (cmacs-journal-filter--file-signature))
    (cmacs-journal-filters-reload)))

(defun cmacs-journal-filter--notify (event)
  "File-notify callback: schedule a reload when EVENT is about our files."
  (let ((names (mapcar (lambda (f) (expand-file-name f))
                       cmacs-journal-filter-files))
        (touched (delq nil (list (nth 2 event) (nth 3 event)))))
    (when (cl-some (lambda (f) (and (stringp f)
                                    (member (expand-file-name f) names)))
                   touched)
      ;; Editors write in several steps (truncate, write, rename); wait
      ;; for them to finish rather than parse half a file and fail.
      (when (timerp cmacs-journal-filter--reload-timer)
        (cancel-timer cmacs-journal-filter--reload-timer))
      (setq cmacs-journal-filter--reload-timer
            (run-with-timer 0.5 nil #'cmacs-journal-filter-check)))))

(defun cmacs-journal-filter-watch ()
  "Watch the filter files' directories for changes."
  (cmacs-journal-filter-unwatch)
  (when (require 'filenotify nil t)
    (let (dirs)
      (dolist (file cmacs-journal-filter-files)
        (let ((dir (file-name-directory (expand-file-name file))))
          (when (and dir (not (file-remote-p dir)) (file-directory-p dir))
            (cl-pushnew dir dirs :test #'equal))))
      (dolist (dir dirs)
        ;; The directory, not the file: an editor that saves by rename
        ;; replaces the inode a file watch was on, and a file that does
        ;; not exist yet has nothing to watch.
        (condition-case nil
            (push (file-notify-add-watch
                   dir '(change) #'cmacs-journal-filter--notify)
                  cmacs-journal-filter--watches)
          (error nil))))))

(defun cmacs-journal-filter-unwatch ()
  "Stop watching the filter files."
  (when (timerp cmacs-journal-filter--reload-timer)
    (cancel-timer cmacs-journal-filter--reload-timer))
  (setq cmacs-journal-filter--reload-timer nil)
  (dolist (w cmacs-journal-filter--watches)
    (ignore-errors (file-notify-rm-watch w)))
  (setq cmacs-journal-filter--watches nil))

;;;; Applying

(defun cmacs-journal-filter--string (value)
  "VALUE of an event field as the string a regexp is matched against."
  (cond ((null value) nil)
        ((stringp value) value)
        ((symbolp value) (symbol-name value))
        ((listp value) (mapconcat (lambda (v) (format "%s" v)) value " "))
        (t (format "%s" value))))

(defun cmacs-journal-filter--match-p (rule event)
  "Non-nil when RULE matches EVENT."
  (and (cl-every (lambda (pair)
                   (let ((s (cmacs-journal-filter--string
                             (plist-get event (car pair)))))
                     (and s (string-match-p (cdr pair) s))))
                 (plist-get rule :match))
       (let ((pred (plist-get rule :predicate)))
         (or (null pred) (funcall pred event)))))

(defun cmacs-journal-filter--hash (value)
  "The short keyed hash standing in for VALUE, or nil without a key."
  (when (and (stringp cmacs-journal-filter-hash-key)
             (not (string-empty-p cmacs-journal-filter-hash-key)))
    (concat "#" (substring
                 (secure-hash 'sha256
                              (concat cmacs-journal-filter-hash-key "\0"
                                      (encode-coding-string value 'utf-8 t)))
                 0 12))))

(defun cmacs-journal-filter--transform (rule event)
  "Apply RULE's drop, replace and hash actions to EVENT, destructively."
  (dolist (field (plist-get rule :drop))
    (setq event (plist-put event field nil)))
  (pcase-dolist (`(,field ,regexp ,with) (plist-get rule :replace))
    (let ((value (plist-get event field)))
      (when value
        (setq event
              (plist-put event field
                         ;; A field that is not text cannot be sanitised
                         ;; in part, so it goes whole.
                         (and (stringp value)
                              (replace-regexp-in-string regexp with value
                                                        t)))))))
  (dolist (field (plist-get rule :hash))
    (let ((value (plist-get event field)))
      (when value
        (setq event
              (plist-put event field
                         (if (and (listp value) (not (stringp value)))
                             (delq nil (mapcar
                                        (lambda (v)
                                          (cmacs-journal-filter--hash
                                           (format "%s" v)))
                                        value))
                           (cmacs-journal-filter--hash
                            (cmacs-journal-filter--string value))))))))
  event)

(defun cmacs-journal-filter-apply (event)
  "Return EVENT as the journal may keep it, or nil to drop it.

EVENT is a plist.  The result is a fresh plist; EVENT is not changed.
Nil means the event is excluded, or that there is no usable rule set, or
that a rule signalled -- in every doubtful case the answer is to keep
nothing.  This never signals: it runs on the compositor's hooks."
  (condition-case nil
      (when (cmacs-journal-filter-ready-p)
        (let ((case-fold-search cmacs-journal-filter-case-fold)
              (matched nil) (excluded nil))
          ;; Every rule is matched against the event as it arrived, so
          ;; one rule's `drop' cannot blind another rule's `exclude'.
          (dolist (rule cmacs-journal-filter--rules)
            (when (and (not excluded)
                       (cmacs-journal-filter--match-p rule event))
              (if (plist-get rule :exclude)
                  (setq excluded t)
                (push rule matched))))
          (unless excluded
            (let ((out (copy-sequence event)))
              ;; `replace' moves the match data, and this runs inside
              ;; other people's hooks.
              (save-match-data
                (dolist (rule (nreverse matched))
                  (setq out (cmacs-journal-filter--transform rule out))))
              out))))
    (error nil)))

;;;; Free text
;;
;; The journal itself never calls this: it keeps no text.  It is here,
;; beside the matcher, so that `cmacs-redact' -- which applies this rule
;; set to everything a model is shown -- does not grow a second one.

(defun cmacs-journal-filter--text-regexp-usable-p (regexp)
  "Non-nil when REGEXP can be searched for inside free text.
A regexp that matches the empty string (`.*', `[0-9]*') means \"the
whole field\" where it was written, and has no meaning inside a larger
text: there it matches between every two characters."
  (not (string-match-p regexp "")))

(defun cmacs-journal-filter--text-rule-p (rule)
  "Non-nil when RULE is written for free text, or decides by a function.
Such a rule already had its say through `cmacs-journal-filter-apply' on
the text event, under its own match; it is not applied a second time."
  (or (plist-get rule :predicate)
      (assq :text (plist-get rule :match))))

(defun cmacs-journal-filter-apply-text (string &optional field-rules)
  "Return STRING as the rule set lets free text be shown.

The result is a string; the symbol `excluded' when a rule excludes the
text as a whole; or nil when there is no usable rule set or a rule
signalled, in which case the caller must show nothing.  This never
signals.

Two things are applied, in this order:

  1. STRING goes through `cmacs-journal-filter-apply' as the event
     (:kind text :text STRING), so a rule matching on the `text' field
     (or by a function) does to it exactly what any rule does to its
     field: `exclude', `drop' (the result is the empty string),
     `replace', `hash'.

  2. With FIELD-RULES non-nil, what the other rules say is sensitive
     inside a FIELD is also searched for in the text, whatever field it
     was written for and whether or not the rule's own match holds --
     free text has no fields to hold it against.  Every `replace' entry
     of such a rule is applied; and for every field a rule both matches
     on and hashes, each occurrence of that match regexp is replaced by
     its keyed hash (blanked without a key).  A regexp that can match
     the empty string is skipped (see
     `cmacs-journal-filter--text-regexp-usable-p'), and one anchored
     to the start or the end of its field only ever matches at the
     start or the end of the whole text.
     An `exclude' or `drop' written for another field has nothing in
     free text to act on and is not applied."
  (condition-case nil
      (when (and (stringp string) (cmacs-journal-filter-ready-p))
        (let ((event (cmacs-journal-filter-apply
                      (list :kind 'text :text string))))
          (if (null event)
              'excluded
            (let ((case-fold-search cmacs-journal-filter-case-fold)
                  (out (plist-get event :text)))
              (setq out (if (stringp out) out ""))
              (when field-rules
                (save-match-data
                  (dolist (rule cmacs-journal-filter--rules)
                    (unless (cmacs-journal-filter--text-rule-p rule)
                      (pcase-dolist (`(,_field ,regexp ,with)
                                     (plist-get rule :replace))
                        (when (cmacs-journal-filter--text-regexp-usable-p
                               regexp)
                          (setq out (replace-regexp-in-string
                                     regexp with out t))))
                      (dolist (field (plist-get rule :hash))
                        (let ((regexp (cdr (assq field
                                                 (plist-get rule :match)))))
                          (when (and regexp
                                     (cmacs-journal-filter--text-regexp-usable-p
                                      regexp))
                            (setq out
                                  (replace-regexp-in-string
                                   regexp
                                   (lambda (match)
                                     (or (cmacs-journal-filter--hash match)
                                         ""))
                                   out t t)))))))))
              out))))
    (error nil)))

;;;; Trying a rule set out

(defun cmacs-journal-filter--format-event (event)
  "EVENT as lines of `field: value', or a line saying it is excluded."
  (if (null event)
      "  (excluded: nothing would be recorded)\n"
    (mapconcat
     (lambda (field)
       (let ((v (plist-get event field)))
         (if v
             (format "  %-8s %s\n" (substring (symbol-name field) 1)
                     (cmacs-journal-filter--string v))
           "")))
     cmacs-journal-filter-fields "")))

;;;###autoload
(defun cmacs-journal-filter-test (event)
  "Show what the journal's filters would make of EVENT.

Interactively, EVENT is what the journal would record right now (the
selected buffer or the focused window); with a prefix argument, type the
fields of a sample instead.  The result is shown, never which rule
produced it."
  (interactive
   (list
    (if current-prefix-arg
        (let (ev)
          (dolist (field '(:kind :app :title :url :file :buffer :project))
            (let ((s (read-string
                      (format "%s (empty for none): "
                              (substring (symbol-name field) 1)))))
              (unless (string-empty-p s)
                (setq ev (plist-put ev field s)))))
          ev)
      (if (fboundp 'cmacs-journal-current-event)
          (funcall 'cmacs-journal-current-event)
        (list :kind 'buffer :buffer (buffer-name)
              :file (and buffer-file-name
                         (abbreviate-file-name buffer-file-name))
              :mode (symbol-name major-mode))))))
  (unless cmacs-journal-filter--loaded
    (cmacs-journal-filters-reload))
  (let ((out (cmacs-journal-filter-apply event)))
    (with-help-window "*cmacs-journal-filter-test*"
      (princ "The event as observed:\n")
      (princ (cmacs-journal-filter--format-event event))
      (princ "\nWhat the journal would keep:\n")
      (princ (if (cmacs-journal-filter-ready-p)
                 (cmacs-journal-filter--format-event out)
               (format "  (nothing: the filters are not loaded)\n  %s\n"
                       (or cmacs-journal-filter--error ""))))))
  nil)

(provide 'cmacs-journal-filter)

;;; cmacs-journal-filter.el ends here
