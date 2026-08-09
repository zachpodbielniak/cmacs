;;; cmacs-brigade-genmail.el --- Agentic mail  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Triage, drafting in your own voice, and a morning briefing, over the
;; mail store you already have.
;;
;; No indexer, no IMAP client, no MIME parser.  `mu' already indexed
;; everything and `mu find --format=sexp' hands it back as Lisp; writing
;; any of that again would be a second implementation of something that
;; already works, and a worse one.
;;
;; Two rules the whole file is built around:
;;
;;   - Nothing is sent without confirmation, and nothing is ever deleted
;;     or moved to spam.  A wrong classification should cost you a
;;     glance, not a lost message.
;;
;;   - A model call is the expensive step, so the cheap deterministic
;;     pass runs first.  A List-Unsubscribe header identifies a
;;     newsletter with certainty; spending a model call to reach the same
;;     answer less reliably is pure waste.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)
(require 'subr-x)
;; Built in, and small: the part decoder reads a charset off every
;; MIME part it renders, so the one function it wants is worth having
;; loaded rather than declared and hoped for.
(require 'mail-parse)

;; cmacs-ai async streaming (present only in a --with-cmacs-ai build).
(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-supported-p "cmacs-ai-stream.c" ())
(declare-function cmacs-brigade--split-model "cmacs-brigade-run" (model))

;; mu4e's move machinery (used only when mu4e is around).
(declare-function mu4e "mu4e" (&optional background))
(declare-function mu4e-running-p "mu4e-server" ())
(declare-function mu4e--server-move "mu4e-server"
                  (docid-or-msgid maildir flags &optional rename no-view))
(declare-function mu4e-get-trash-folder "mu4e-folders" (msg))
(declare-function mu4e-get-refile-folder "mu4e-folders" (msg))
(declare-function mu4e-update-mail-and-index "mu4e-update" (run-in-background))

(defgroup cmacs-brigade-genmail nil
  "Agentic mail over an existing mu index."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-genmail-")

(defcustom cmacs-brigade-genmail-mu-program "mu"
  "The mu binary."
  :type 'string
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-self-addresses nil
  "Your own addresses, used to find sent mail and infer relationships.
Derived from mu4e when it is configured and this is nil."
  :type '(repeat string)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-sent-query nil
  "Query selecting your sent mail, for the style corpus.
Derived from `cmacs-brigade-genmail-self-addresses' when nil."
  :type '(choice (const :tag "Derive it" nil) string)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-inbox-query nil
  "Query selecting the folders triage and the briefing read.

Nil derives it from the store: every maildir whose last component is an
inbox, which covers a single account and one INBOX per account alike.

Unread mail that has already been filed is unread on purpose -- an
archive of things read later, a list folder nobody opens -- and hauling
it back out every morning buries the mail that actually arrived."
  :type '(choice (const :tag "Derive it" nil) string)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-triage-model "ollama/qwen3.5:9b"
  "Model used for triage.

A local model by default.  Triage runs over every unread inbox message
every morning, and paying a frontier model to sort mail is a poor trade
when the task is mostly pattern recognition.

This one specifically because it answers.  Local models vary far more in
how long they take, and in whether they honour a requested output form,
than their parameter counts suggest: on the same three-message batch
qwen3.5:9b answered in the requested form in ~84s where gemma4:12b
produced nothing in 400s.  Measure before trusting a morning job to a
different one."
  :type 'string
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-use-model t
  "Whether triage asks a model about what the rules could not decide.

Off means rules only: everything the deterministic pass does not
recognise is filed under `reply', which is the safe guess but not an
informative one.  Requires a `--with-cmacs-ai' build either way."
  :type 'boolean
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-triage-timeout 600
  "Seconds to wait for the triage model before falling back to rules.

A local model that is cold, swapping or wedged would otherwise mean no
report at all -- which for a job that runs before you wake up is the
worst outcome, worse than a rules-only one.  nil waits forever.

Generous on purpose: a cold 12B answering a full batch takes minutes,
and a timeout that fires mid-answer throws away work that was nearly
done.  Raise it if `cmacs-brigade-genmail-max-triage' is large."
  :type '(choice (const :tag "No timeout" nil) integer)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-draft-model nil
  "Model used for drafting.  Falls back to `cmacs-brigade-default-model'.

Worth more than the triage model: this one writes in your name."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-output-directory nil
  "Where triage reports and the voice profile are written.
Defaults under `cmacs-brigade-state-dir'."
  :type '(choice (const :tag "Default" nil) directory)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-daily-note-function nil
  "Function returning today's note file, for the briefing.
Called with no arguments."
  :type '(choice (const :tag "None" nil) function)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-apply-flags nil
  "Whether triage may set mu4e flags on messages.

Off by default.  Triage is a suggestion until you have watched it be
right for a while, and a wrong flag on real mail is a real cost."
  :type 'boolean
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-work-domains nil
  "Domain suffixes that mark an address as work correspondence."
  :type '(repeat string)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-max-triage 40
  "Most messages to triage in one pass."
  :type 'integer
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-address-rules nil
  "Alist of (REGEXP . BUCKET) matched against the sender's address.

Checked before every built-in rule and before the model, so this is
where a sender that keeps being judged wrong is settled once and for
all.  BUCKET must be one of `cmacs-brigade-genmail-buckets'; an entry
naming anything else is ignored rather than inventing a section the
report would never print."
  :type '(alist :key-type regexp :value-type symbol)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-subject-rules nil
  "Alist of (REGEXP . BUCKET) matched against the subject, lower-cased.
Same contract as `cmacs-brigade-genmail-address-rules', checked right
after it."
  :type '(alist :key-type regexp :value-type symbol)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-trash-folder nil
  "Maildir the trash button moves mail into, e.g. \"/Trash\".
A function is called with the message plist and returns the maildir.
Nil derives it from mu4e (`mu4e-trash-folder') when mu4e is around."
  :type '(choice (const :tag "Derive from mu4e" nil) string function)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-archive-folder nil
  "Maildir the archive button moves mail into, e.g. \"/Archive\".
Same contract as `cmacs-brigade-genmail-trash-folder', derived from
`mu4e-refile-folder' when nil."
  :type '(choice (const :tag "Derive from mu4e" nil) string function)
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-trash-flags "-N"
  "Flags passed to the mu4e server when trashing.

Not \"+T-N\" (stock mu4e trash) on purpose.  Under mbsync with
`Expunge Both', a local file carrying the T flag and no remote UID
reads as \"marked deleted, never uploaded\" and is expunged locally
without the delete ever reaching the server.  Moving into the trash
maildir already is the delete; the T flag is redundant there and
destructive here.  Set this to \"+T-N\" only when the store is not
synced by mbsync."
  :type 'string
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-confirm-moves t
  "Whether the trash and archive buttons ask before moving.

On by default: mu4e's own flow is mark then execute, two deliberate
steps, and a single org-link click should not be quieter than that."
  :type 'boolean
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-sync-after-move t
  "Whether to run mu4e's mail update after a report-button move.

Mirrors executing marks inside mu4e: the move is only local until
mbsync pushes it, and a trash that never reaches the server is not a
trash.  Debounced, so a burst of clicks syncs once."
  :type 'boolean
  :group 'cmacs-brigade-genmail)

(defcustom cmacs-brigade-genmail-todo-file-function nil
  "Function returning the file the todo button appends to.

Nil derives it: the org-roam daily for today when org-roam's dailies
are configured, else `cmacs-brigade-genmail-daily-note-function'."
  :type '(choice (const :tag "Derive it" nil) function)
  :group 'cmacs-brigade-genmail)

(define-error 'cmacs-brigade-genmail-error
  "GenMail error" 'cmacs-brigade-error)


;;;; The query layer
;;
;; One function.  Everything else composes from it.

(defvar cmacs-brigade-genmail--available nil
  "Cached result of `cmacs-brigade-genmail-available-p'.")

(defun cmacs-brigade-genmail-available-p (&optional recheck)
  "Return non-nil when mu is installed *and* has a usable index.

The binary being present is not enough: mu exits 1 with \"failed to open
database\" when it has never indexed anything, or when XDG points
somewhere it has not.  Treating that as available turns every mail
function into an error report instead of a graceful no.

The answer is cached, since it involves running mu; pass RECHECK after
running `mu init'."
  (when (or recheck (null cmacs-brigade-genmail--available))
    (setq cmacs-brigade-genmail--available
          (if (not (executable-find cmacs-brigade-genmail-mu-program))
              'no
            (with-temp-buffer
              ;; `mu info' answers without searching, so this costs
              ;; nothing on a large store.
              (if (eq 0 (call-process cmacs-brigade-genmail-mu-program
                                      nil t nil "info"))
                  'yes 'no)))))
  (eq cmacs-brigade-genmail--available 'yes))

(defun cmacs-brigade-genmail--self-addresses ()
  "Return your addresses, from configuration or mu4e."
  (or cmacs-brigade-genmail-self-addresses
      (and (boundp 'mu4e-user-mail-address-list)
           (symbol-value 'mu4e-user-mail-address-list))
      (and (boundp 'user-mail-address) (list user-mail-address))))

(defun cmacs-brigade-genmail-query (query &optional maxnum fields)
  "Run mu find for QUERY and return a list of plists.

FIELDS defaults to a useful set.  Returns nil rather than signalling when
mu finds nothing: an empty inbox is a normal Tuesday, not an error."
  (unless (cmacs-brigade-genmail-available-p)
    (signal 'cmacs-brigade-genmail-error (list "mu is not installed")))
  (with-temp-buffer
    (let ((status (apply #'call-process
                         cmacs-brigade-genmail-mu-program nil t nil
                         (append (list "find" "--format=sexp"
                                       "--maxnum"
                                       (number-to-string (or maxnum 50)))
                                 (when fields (list "--fields" fields))
                                 (list query)))))
      ;; mu exits 2 for "no matches", which is an answer rather than a
      ;; failure -- an empty inbox is a normal Tuesday.  4 is accepted
      ;; too because older mu used it for the same thing.
      (cond
       ((memq status '(0)) (cmacs-brigade-genmail--read-sexps))
       ((memq status '(2 4)) nil)
       (t (signal 'cmacs-brigade-genmail-error
                  (list (format "mu find exited %s" status)
                        (buffer-string))))))))

(defun cmacs-brigade-genmail--read-sexps ()
  "Read every sexp in the current buffer into a list."
  (goto-char (point-min))
  (let (out)
    (condition-case nil
        (while t (push (read (current-buffer)) out))
      (end-of-file nil)
      (error nil))
    (nreverse out)))

(defvar cmacs-brigade-genmail--maildirs nil
  "Cached maildir list, or the symbol `none' when mu would not answer.")

(defun cmacs-brigade-genmail-maildirs (&optional recheck)
  "Return the maildirs in the store as a list of strings.

Answered by `mu info maildirs', which reads the store rather than
searching it, so this is cheap.  The answer is cached; pass RECHECK
after adding an account."
  (when (or recheck (null cmacs-brigade-genmail--maildirs))
    (setq cmacs-brigade-genmail--maildirs
          (or (and (cmacs-brigade-genmail-available-p)
                   (with-temp-buffer
                     (when (eq 0 (call-process
                                  cmacs-brigade-genmail-mu-program
                                  nil t nil "info" "maildirs"))
                       (cl-remove-if-not
                        (lambda (l) (string-prefix-p "/" l))
                        (split-string (buffer-string) "\n" t "[ \t\r]+")))))
              'none)))
  (if (eq cmacs-brigade-genmail--maildirs 'none)
      nil
    cmacs-brigade-genmail--maildirs))

(defun cmacs-brigade-genmail--inbox-maildirs ()
  "Return the maildirs whose last component names an inbox."
  (cl-remove-if-not
   (lambda (d)
     (string-equal "inbox"
                   (downcase (file-name-nondirectory
                              (directory-file-name d)))))
   (cmacs-brigade-genmail-maildirs)))

(defun cmacs-brigade-genmail--inbox-query ()
  "Return the query restricting mail to the inbox.

Each maildir is quoted, since a maildir name may contain spaces."
  (or cmacs-brigade-genmail-inbox-query
      (let ((dirs (cmacs-brigade-genmail--inbox-maildirs)))
        ;; Falling back to \"the whole store\" would quietly reinstate
        ;; the behaviour this exists to prevent, so an unrecognisable
        ;; store falls back to the conventional name instead: a morning
        ;; with nothing to triage is a visible wrong answer, a morning
        ;; triaging the archive is an invisible one.
        (if dirs
            (mapconcat (lambda (d) (format "maildir:\"%s\"" d)) dirs " OR ")
          "maildir:/INBOX"))))

(defun cmacs-brigade-genmail--unread-query ()
  "Return the query for unread mail worth looking at.

The inbox only.  Spam stays excluded by name as well, for the case where
`cmacs-brigade-genmail-inbox-query' has been widened by hand."
  (format "flag:unread AND NOT maildir:/Spam AND (%s)"
          (cmacs-brigade-genmail--inbox-query)))

(defun cmacs-brigade-genmail-body (path)
  "Return the plain-text body of the message at PATH."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (cmacs-brigade-genmail--strip-headers)
      (cmacs-brigade-genmail--strip-quotes)
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun cmacs-brigade-genmail--strip-headers ()
  "Delete everything up to the first blank line."
  (goto-char (point-min))
  (when (re-search-forward "^$" nil t)
    (delete-region (point-min) (point))))

(defun cmacs-brigade-genmail--strip-quotes ()
  "Delete quoted passages, signatures and forwarded tails.

Everything below is about *your* writing; quoted text is someone else's
and would teach the model their voice instead of yours."
  (goto-char (point-min))
  (while (re-search-forward "^>.*$" nil t)
    (replace-match ""))
  (goto-char (point-min))
  (when (re-search-forward "^-- ?$" nil t)
    (delete-region (match-beginning 0) (point-max)))
  (goto-char (point-min))
  (when (re-search-forward
         "^\\(On .* wrote:\\|-----Original Message-----\\|_+$\\)" nil t)
    (delete-region (match-beginning 0) (point-max)))
  (goto-char (point-min))
  (while (re-search-forward "\n\\{3,\\}" nil t)
    (replace-match "\n\n")))


;;;; Voice
;;
;; A derived profile, not two hundred raw emails stuffed into a prompt.
;; The raw approach burns tokens and produces worse results, because the
;; model imitates whichever example is nearest rather than the pattern.

(defun cmacs-brigade-genmail--output-dir ()
  (or cmacs-brigade-genmail-output-directory
      (expand-file-name "genmail" cmacs-brigade-state-dir)))

(defun cmacs-brigade-genmail--sent-query ()
  (or cmacs-brigade-genmail-sent-query
      (let ((me (cmacs-brigade-genmail--self-addresses)))
        (if me
            (mapconcat (lambda (a) (format "from:%s" a)) me " OR ")
          "maildir:/Sent"))))

(defun cmacs-brigade-genmail--bucket-for (address)
  "Classify ADDRESS as `work', `personal', `vendor' or `list'."
  (let ((a (downcase (or address ""))))
    (cond
     ((string-match-p "noreply\\|no-reply\\|donotreply\\|notifications?@" a)
      'vendor)
     ((string-match-p "\\(^\\|[.@]\\)\\(lists?\\|group\\)[.@]" a) 'list)
     ((cl-some (lambda (d) (string-suffix-p d a))
               cmacs-brigade-genmail-work-domains)
      'work)
     (t 'personal))))

(defun cmacs-brigade-genmail--style-features (bodies)
  "Compute style measurements over BODIES."
  (let* ((n (max 1 (length bodies)))
         (words 0) (sentences 0) (contractions 0) (exclamations 0)
         (greetings 0) (signoffs 0) (lengths nil))
    (dolist (b bodies)
      (let ((w (length (split-string b "[ \t\n]+" t))))
        (push w lengths)
        (setq words (+ words w)
              sentences (+ sentences (max 1 (cl-count-if
                                             (lambda (c) (memq c '(?. ?? ?!)))
                                             (string-to-list b))))
              contractions (+ contractions
                              (cl-count-if (lambda (_) t)
                                           (split-string b "'" t)))
              exclamations (+ exclamations (cl-count ?! (string-to-list b))))
        (when (string-match-p "\\`\\(Hi\\|Hello\\|Hey\\|Dear\\)" (string-trim b))
          (setq greetings (1+ greetings)))
        (when (string-match-p
               "\\(Thanks\\|Cheers\\|Best\\|Regards\\|-[A-Z]\\)[,.]?[ \t]*\\'"
               (string-trim b))
          (setq signoffs (1+ signoffs)))))
    (list :samples n
          :mean-words (/ words n)
          :mean-sentence-words (if (> sentences 0) (/ words sentences) 0)
          :greeting-rate (/ (float greetings) n)
          :signoff-rate (/ (float signoffs) n)
          :exclamations-per-mail (/ (float exclamations) n)
          :median-words (if lengths
                            (nth (/ (length lengths) 2) (sort lengths #'<))
                          0))))

;;;###autoload
(defun cmacs-brigade-genmail-build-voice (&optional limit)
  "Build a voice profile from your sent mail.  Returns the profile."
  (interactive)
  (unless (cmacs-brigade-genmail-available-p)
    (user-error "cmacs-brigade: mu is not installed"))
  (let* ((msgs (cmacs-brigade-genmail-query
                (cmacs-brigade-genmail--sent-query) (or limit 200)))
         (buckets (make-hash-table :test 'eq))
         profile)
    (dolist (m msgs)
      (let* ((addr (cmacs-brigade-genmail--address (car (plist-get m :to))))
             (bucket (cmacs-brigade-genmail--bucket-for addr))
             (body (cmacs-brigade-genmail-body (plist-get m :path))))
        (when (and body (> (length (string-trim body)) 20))
          (push body (gethash bucket buckets)))))
    (maphash
     (lambda (bucket bodies)
       (push (list :bucket bucket
                   :features (cmacs-brigade-genmail--style-features bodies)
                   ;; A handful of real examples, chosen for length
                   ;; spread so the model sees both a one-liner and a
                   ;; considered reply rather than twelve of the same.
                   :exemplars (cmacs-brigade-genmail--pick-exemplars bodies))
             profile))
     buckets)
    (cmacs-brigade-genmail--write-voice profile)
    (when (called-interactively-p 'any)
      (message "cmacs-brigade: voice profile from %d sent messages, %d buckets"
               (length msgs) (length profile)))
    profile))

(defun cmacs-brigade-genmail--pick-exemplars (bodies &optional n)
  "Pick N bodies spanning the range of lengths in BODIES."
  (let* ((n (or n 12))
         (sorted (sort (copy-sequence bodies)
                       (lambda (a b) (< (length a) (length b)))))
         (total (length sorted)))
    (if (<= total n) sorted
      (cl-loop for i from 0 below n
               collect (nth (/ (* i (1- total)) (max 1 (1- n))) sorted)))))

(defun cmacs-brigade-genmail--voice-file ()
  (expand-file-name "voice.eld" (cmacs-brigade-genmail--output-dir)))

(defun cmacs-brigade-genmail--write-voice (profile)
  (make-directory (cmacs-brigade-genmail--output-dir) t)
  (with-temp-file (cmacs-brigade-genmail--voice-file)
    (let ((print-length nil) (print-level nil))
      (prin1 profile (current-buffer))
      (insert "\n"))))

(defun cmacs-brigade-genmail-voice (&optional bucket)
  "Return the stored voice profile, or the entry for BUCKET."
  (let ((f (cmacs-brigade-genmail--voice-file)))
    (when (file-readable-p f)
      (let ((p (with-temp-buffer (insert-file-contents f)
                                 (read (current-buffer)))))
        (if bucket
            (cl-find bucket p :key (lambda (e) (plist-get e :bucket)))
          p)))))


;;;; Report links
;;
;; The report writes `mu4e:msgid:...' links, which mu4e's own `mu4e-org'
;; knows how to follow.  But `mu4e-org' is not loaded in every session
;; that opens a report, and an unregistered link type is not an error in
;; org -- it falls through to a heading search, so following the link
;; asks "No match - create this as a new heading?" instead of opening
;; the mail.  A report whose links do not open the message is a report
;; you have to go looking from, which was the whole thing it existed to
;; avoid.

(declare-function mu4e-view-message-with-message-id "mu4e-view" (msgid))
(declare-function mm-dissect-buffer "mm-decode"
                  (&optional no-strict-mime loose-mime from))
(declare-function mm-handle-media-type "mm-decode" (handle))
(declare-function mm-get-part "mm-decode" (handle &optional no-cache))
(declare-function shr-insert-document "shr" (dom))
(declare-function rfc2047-decode-string "rfc2047" (string &optional address))
(declare-function mm-handle-type "mm-decode" (handle))
(declare-function mail-content-type-get "mail-parse" (ct attribute))
;; Declared so `let' binds shr's own dynamic variables.  Without this the
;; compiler has never seen them -- shr is required at run time, not load
;; time -- and binds fresh lexicals instead, so the rendering silently
;; ignores every setting (a message rendered one word per line).
(defvar shr-width)
(defvar shr-use-fonts)
(defvar shr-inhibit-images)
(declare-function org-link-get-parameter "ol" (type key))
(declare-function org-link-set-parameters "ol" (type &rest parameters))

(defun cmacs-brigade-genmail-open-msgid (msgid)
  "Open the message with MSGID for reading.

Prefers mu4e, which gives a real message view with attachments and
replies.  Without it the raw file is opened read-only -- less pleasant,
but it is the message, and mu can always find it because mu is what
indexed it."
  (interactive "sMessage id: ")
  (or (and (or (featurep 'mu4e) (require 'mu4e nil t))
           (require 'mu4e-view nil t)
           (fboundp 'mu4e-view-message-with-message-id)
           (progn (mu4e-view-message-with-message-id msgid) t))
      (let* ((msg (car (cmacs-brigade-genmail-query
                        (format "msgid:%s" msgid) 1)))
             (path (plist-get msg :path)))
        (unless (and path (file-readable-p path))
          (user-error "cmacs-brigade: no readable message for %s" msgid))
        (cmacs-brigade-genmail--view-file path)
        t)))

(defvar cmacs-brigade-genmail--view-path nil
  "Path of the message shown in the current view buffer.")

(defun cmacs-brigade-genmail-message-text (path)
  "Return the readable text of the message at PATH.

MIME decoded, charset honoured, HTML rendered.  This is what a person
would read, which is also what is worth showing a model -- distinct
from `cmacs-brigade-genmail-body', which strips quoted passages and
signatures because it feeds the voice profile."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (or (cmacs-brigade-genmail--decoded-text) ""))))

(defun cmacs-brigade-genmail--view-file (path)
  "Show the message at PATH in a readable buffer.

Not the raw file: a newsletter is a hundred kilobytes of base64 and
HTML, and the point of following the link is to decide what to do with
the message, which you cannot do while reading MIME.  Headers, then the
text of the message.  `C-c C-r' gets the raw file when the rendering
loses something that mattered."
  (let ((buf (get-buffer-create "*genmail message*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents path)
        (cmacs-brigade-genmail--render-message)
        (goto-char (point-min))
        (setq cmacs-brigade-genmail--view-path path))
      (cmacs-brigade-genmail-view-mode))
    (pop-to-buffer buf)))

(defun cmacs-brigade-genmail--render-message ()
  "Replace the raw message in the current buffer with a readable form."
  (let* ((headers (cmacs-brigade-genmail--header-block))
         (body (or (cmacs-brigade-genmail--decoded-text) "")))
    (erase-buffer)
    (insert headers "\n" (string-trim body) "\n")))

(defun cmacs-brigade-genmail--decode-header (value)
  "Return VALUE unfolded and RFC2047-decoded.

Subjects arrive as \"=?utf-8?q?...?=\" often enough that a header block
without this is less readable than the raw file it replaced."
  (let ((flat (string-trim (replace-regexp-in-string "[ \t\n]+" " " value))))
    (or (ignore-errors
          (require 'rfc2047)
          (rfc2047-decode-string flat))
        flat)))

(defun cmacs-brigade-genmail--header-block ()
  "Return the headers worth reading, from the raw message in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((end (save-excursion (or (re-search-forward "^$" nil t) (point-max))))
          (out ""))
      (dolist (field '("From" "To" "Cc" "Date" "Subject"))
        (goto-char (point-min))
        ;; Continuation lines are folded back in: a long Subject wraps,
        ;; and half a subject line is worse than none.
        (when (re-search-forward
               (format "^%s:[ \t]*\\(.*\\(?:\n[ \t]+.*\\)*\\)" field) end t)
          ;; Decoded, or a subject arrives as "=?utf-8?q?..?=" and the
          ;; header block is less readable than the raw file was.
          (setq out (concat out (format "%-8s %s\n" (concat field ":")
                                        (cmacs-brigade-genmail--decode-header
                                         (match-string 1)))))))
      out)))

(defun cmacs-brigade-genmail--flatten-handles (handles)
  "Return the leaf MIME handles in HANDLES.

`mm-dissect-buffer' answers a single handle for a simple message and a
tree whose car is the multipart type otherwise; both shapes have to be
walked or a multipart/alternative newsletter renders as nothing."
  (cond
   ((null handles) nil)
   ((bufferp (car-safe handles)) (list handles))
   ((stringp (car-safe handles))
    (apply #'append (mapcar #'cmacs-brigade-genmail--flatten-handles
                            (cdr handles))))
   ((listp handles)
    (apply #'append (mapcar #'cmacs-brigade-genmail--flatten-handles handles)))
   (t nil)))

(defun cmacs-brigade-genmail--part-text (handle)
  "Return HANDLE's content as text, decoded to its declared charset.

`mm-get-part' undoes the transfer encoding but hands back unibyte
bytes; inserting those into a multibyte buffer renders every smart
quote as mojibake.  The charset is on the part, so use it, and fall
back to utf-8, which is what mail that does not say is."
  (let* ((raw (mm-get-part handle))
         (charset (or (ignore-errors
                        (mail-content-type-get (mm-handle-type handle)
                                               'charset))
                      "utf-8"))
         (coding (ignore-errors
                   (coding-system-from-name (format "%s" charset)))))
    (if (and (stringp raw) (not (multibyte-string-p raw)))
        (or (ignore-errors
              (decode-coding-string raw (or coding 'utf-8) t))
            raw)
      raw)))

(defun cmacs-brigade-genmail--render-html (html)
  "Return HTML rendered as text via shr, or nil."
  (ignore-errors
    (require 'shr)
    (when (fboundp 'libxml-parse-html-region)
      (with-temp-buffer
        (insert html)
        (let ((dom (libxml-parse-html-region (point-min) (point-max))))
          (erase-buffer)
          ;; Bounded width: shr defaults to the window, and a message
          ;; rendered at the width of a full-frame window is unreadable
          ;; in a split one.
          (let ((shr-width 78)
                (shr-use-fonts nil)
                (shr-inhibit-images t))
            (shr-insert-document dom))
          (buffer-substring-no-properties (point-min) (point-max)))))))

(defun cmacs-brigade-genmail--decoded-text ()
  "Return the message body as text, decoding MIME where possible.

Prefers a text/plain part; renders text/html through shr when that is
all there is, which for most mail that arrives now is the only part."
  (or (ignore-errors
        (require 'mm-decode)
        (let* ((parts (cmacs-brigade-genmail--flatten-handles
                       (mm-dissect-buffer t)))
               (type-of (lambda (h) (or (ignore-errors
                                          (mm-handle-media-type h)) "")))
               (plain (cl-find "text/plain" parts :key type-of :test #'equal))
               (html (cl-find "text/html" parts :key type-of :test #'equal))
               (pick (or plain html (car parts))))
          (when pick
            ;; `mm-get-part' undoes base64/quoted-printable; displaying
            ;; the handle inline does not, which is how a newsletter
            ;; ends up on screen as "=3D" soup.
            (let ((text (cmacs-brigade-genmail--part-text pick)))
              (if (equal (funcall type-of pick) "text/html")
                  (or (cmacs-brigade-genmail--render-html text) text)
                text)))))
      ;; Nothing decoded: everything after the first blank line, which is
      ;; at least the message as it arrived.
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^$" nil t)
          (buffer-substring-no-properties (point) (point-max))))))

(defun cmacs-brigade-genmail-view-raw ()
  "Open the raw file behind the current message view."
  (interactive)
  (unless cmacs-brigade-genmail--view-path
    (user-error "cmacs-brigade: no message here"))
  (find-file-read-only cmacs-brigade-genmail--view-path))

(defvar cmacs-brigade-genmail-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'cmacs-brigade-genmail-view-raw)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-brigade-genmail-view-mode'.")

(define-derived-mode cmacs-brigade-genmail-view-mode special-mode "GenMail"
  "Major mode for reading one message opened from a triage report."
  (setq-local cmacs-brigade-genmail--view-path cmacs-brigade-genmail--view-path))

(defun cmacs-brigade-genmail--follow-link (link &optional _prefix)
  "Follow LINK, the path part of a `mu4e:' org link.

Only the `msgid:' form is handled -- it is the only form this report
writes, and guessing at mu4e's query syntax would be pretending to be
mu4e rather than standing in for it."
  (if (string-match "\\`msgid:\\(.+\\)\\'" link)
      (cmacs-brigade-genmail-open-msgid (match-string 1 link))
    (user-error "cmacs-brigade: unsupported mu4e link: %s" link)))

(defun cmacs-brigade-genmail--follow-retriage (path &optional _prefix)
  "Follow PATH, the path part of a `cmacs-genmail:' report link.

The report's buttons: `retriage:all', `retriage:bucket:NAME' and
`retriage:msgid:ID' for second opinions; `trash:ID', `archive:ID' and
`todo:ID' for acting on one message."
  (cond
   ((string-equal path "retriage:all")
    (cmacs-brigade-genmail-reclassify 'all))
   ((string-match "\\`retriage:bucket:\\([a-z-]+\\)\\'" path)
    (cmacs-brigade-genmail-reclassify
     (cons 'bucket (intern (match-string 1 path)))))
   ((string-match "\\`retriage:msgid:\\(.+\\)\\'" path)
    (cmacs-brigade-genmail-reclassify
     (cons 'msgid (match-string 1 path))))
   ((string-match "\\`trash:\\(.+\\)\\'" path)
    (cmacs-brigade-genmail-trash-message (match-string 1 path)))
   ((string-match "\\`archive:\\(.+\\)\\'" path)
    (cmacs-brigade-genmail-archive-message (match-string 1 path)))
   ((string-match "\\`todo:\\(.+\\)\\'" path)
    (cmacs-brigade-genmail-log-todo (match-string 1 path)))
   (t (user-error "cmacs-brigade: unsupported genmail link: %s" path))))

(defun cmacs-brigade-genmail-ensure-link-type ()
  "Make sure the links a triage report writes actually do something.

For `mu4e:' links, loads mu4e's own handler when it can and stands in
only when there is nothing registered at all -- if `mu4e-org' loads
later it re-registers the type and wins, which is the right outcome.
The `cmacs-genmail:' retriage links are ours alone, so those are simply
registered."
  (require 'ol nil t)
  (when (and (fboundp 'org-link-set-parameters)
             (fboundp 'org-link-get-parameter))
    (unless (require 'mu4e-org nil t)
      (when (null (org-link-get-parameter "mu4e" :follow))
        (org-link-set-parameters
         "mu4e" :follow #'cmacs-brigade-genmail--follow-link)))
    (org-link-set-parameters
     "cmacs-genmail" :follow #'cmacs-brigade-genmail--follow-retriage)))

(with-eval-after-load 'org
  (cmacs-brigade-genmail-ensure-link-type))


;;;; Triage

(defvar cmacs-brigade-genmail--inflight nil
  "Non-nil while a triage model pass is running.

One at a time: two async passes rewriting the same report would race,
and the loser's answer would look like it never came.")

(defconst cmacs-brigade-genmail-buckets
  '(act-now reply waiting-on-me fyi newsletter receipt noise)
  "The buckets triage sorts into, in report order.")

(defconst cmacs-brigade-genmail-actions
  '(trash archive reply todo triage)
  "The actions triage may recommend for a message.

`trash' and `archive' have buttons that do the move; `todo' has one
that logs the message on the day's list; `reply' and `triage' are the
reader's -- one is answered in mu4e, the other means a human has to
look before anything is decided.")

(defun cmacs-brigade-genmail--default-action (bucket)
  "Return the recommended action implied by BUCKET alone.

Used for rule-decided messages, where no model was asked, and as the
fallback when the model named a bucket but no action.  Deliberately
conservative at the edges: an unrecognised bucket recommends `triage',
never a move."
  (pcase bucket
    ('act-now 'todo)
    ('reply 'reply)
    ('waiting-on-me 'todo)
    ('fyi 'archive)
    ('newsletter 'trash)
    ('receipt 'archive)
    ('noise 'trash)
    (_ 'triage)))

(defconst cmacs-brigade-genmail--attention-subject-re
  (concat "security\\|alert\\|fraud\\|suspicious\\|unauthorized\\|"
          "verif\\|password\\|sign.?in\\|log.?in\\|expir\\|deadline\\|"
          "action required\\|urgent\\|account\\|credit\\|statement\\|"
          "report\\|balance\\|renew\\|overdue")
  "Subjects no rule may file as newsletter or noise.

Security, money and the account itself: exactly where a wrong bucket
costs the most, and bulk senders mail about all three -- Credit Karma
sets List-Unsubscribe on a credit-report change, Google sends security
alerts from a noreply address.  A subject matching this goes to the
model, whatever the headers say.")

(defun cmacs-brigade-genmail--custom-rule (addr subject)
  "Return the bucket the user's own rules assign, or nil.

ADDR and SUBJECT are already lower-cased.  A rule naming a bucket that
is not in `cmacs-brigade-genmail-buckets' is skipped: a typo there must
not create a section the report never prints."
  (cl-loop for (re . bucket)
           in (append (mapcar (lambda (r) (cons (car r) (cons 'addr (cdr r))))
                              cmacs-brigade-genmail-address-rules)
                      (mapcar (lambda (r) (cons (car r) (cons 'subj (cdr r))))
                              cmacs-brigade-genmail-subject-rules))
           when (and (memq (cdr bucket) cmacs-brigade-genmail-buckets)
                     (string-match-p re (if (eq (car bucket) 'addr)
                                            addr subject)))
           return (cdr bucket)))

(defun cmacs-brigade-genmail--obviously-automated-p (msg)
  "Return a bucket symbol when MSG can be classified with no model.

Only what a rule can know with certainty.  An earlier version of this
also guessed -- `noreply' in the sender meant noise, a bulk-mail domain
meant newsletter -- and the guesses were wrong exactly where being
wrong mattered: security alerts come from noreply addresses, and
credit-report notices arrive from mail.<bank>.com.  A rule that cannot
be certain now answers nil and the model decides."
  (let* ((addr (downcase (or (cmacs-brigade-genmail--address
                              (car (plist-get msg :from))) "")))
         (subject (downcase (or (plist-get msg :subject) ""))))
    (cond
     ;; The user's own rules outrank everything, the attention guard
     ;; included: a sender they have already ruled on is settled.
     ((cmacs-brigade-genmail--custom-rule addr subject))
     ;; Transactional subjects are precise enough to trust.
     ((string-match-p
       "\\(receipt\\|invoice\\|your order\\|order .* confirmed\\|payment \\(received\\|due\\)\\|shipped\\)"
       subject)
      'receipt)
     ;; Security, money, the account: never rule-filed, whatever the
     ;; headers say.  See `cmacs-brigade-genmail--attention-subject-re'.
     ((string-match-p cmacs-brigade-genmail--attention-subject-re subject)
      nil)
     ;; With the guard above already passed, a mailing-list header is
     ;; conclusive, and a sender announcing itself as a newsletter is
     ;; close enough.
     ((plist-get msg :list) 'newsletter)
     ((string-match-p "newsletter\\|digest" addr) 'newsletter)
     (t nil))))

(defun cmacs-brigade-genmail--ai-available-p ()
  "Non-nil when the cmacs-ai layer is built and reports itself usable.

Loaded on demand, so triage works in a session where no AI command has
run yet."
  (and (or (featurep 'cmacs-ai) (require 'cmacs-ai nil t))
       (fboundp 'cmacs-ai-make-session)
       (fboundp 'cmacs-ai-chat-stream)
       (ignore-errors (cmacs-ai-supported-p))))

(defun cmacs-brigade-genmail--triage-file ()
  "Return the path today's triage report is written to.

Computed rather than discovered, so `cmacs-brigade-genmail-triage' can
name the file it will produce before the model has answered."
  (expand-file-name (format-time-string "%Y-%m-%d_triage.org")
                    (cmacs-brigade-genmail--output-dir)))

(defun cmacs-brigade-genmail--split-model (model)
  "Split MODEL, a \"provider/name\" string, into (PROVIDER . NAME).

Delegates to brigade's own parser so the spelling is the same everywhere,
loading it on demand: genmail runs fine in a build with no AI at all, so
the dependency stays lazy rather than becoming a top-level `require'."
  (unless (fboundp 'cmacs-brigade--split-model)
    (require 'cmacs-brigade-run nil t))
  (if (fboundp 'cmacs-brigade--split-model)
      (cmacs-brigade--split-model model)
    (if (and model (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" model))
        (cons (intern (match-string 1 model)) (match-string 2 model))
      (cons nil model))))

(defun cmacs-brigade-genmail--triage-system-prompt ()
  "Return the system prompt for the triage model."
  (concat
   "You sort a person's unread mail into exactly one bucket each.\n\n"
   "Buckets:\n"
   "  act-now       needs attention today; a deadline, an outage, money at\n"
   "                risk, a security alert about a sign-in that may not be theirs\n"
   "  reply         a person is waiting on a response from the reader\n"
   "  waiting-on-me someone downstream is blocked until the reader acts\n"
   "  fyi           worth reading, needs nothing: account notices, statements,\n"
   "                reports about the reader's money or accounts, routine\n"
   "                security confirmations\n"
   "  newsletter    bulk or subscription content sent to a list\n"
   "  receipt       transactional: orders, invoices, payments, shipping\n"
   "  noise         nothing to read and nothing to do: marketing blasts,\n"
   "                promotional offers, social-network activity\n\n"
   "A security alert or a notice about the reader's own account or money\n"
   "is never noise and never newsletter, even when the sender is bulk\n"
   "mail.  When fyi and noise both fit, prefer fyi.\n\n"
   "After the bucket, recommend exactly one action:\n"
   "  trash    nothing of value; delete it\n"
   "  archive  worth keeping for reference; file it\n"
   "  reply    the reader should answer it\n"
   "  todo     the reader must do something beyond replying\n"
   "  triage   you are not sure; a human should look\n\n"
   "When unsure of the action, say triage rather than trash: a wrong\n"
   "triage costs a glance, a wrong trash costs a message.\n\n"
   "Output the answer template with each BUCKET replaced by one bucket\n"
   "name and each ACTION by one action name.  Output nothing else: no\n"
   "preamble, no reasoning, no markdown, no table, no restating of the\n"
   "messages."))

(defun cmacs-brigade-genmail--triage-prompt (msgs)
  "Return the user prompt classifying MSGS, numbered from 1.

Each message contributes sender, subject and a short body excerpt.  The
excerpt is short on purpose: the bucket is nearly always decidable from
the opening, and full bodies would blow up a local model's context for
no better answer."
  (concat
   ;; The rules live in the user turn as well as the system prompt.
   ;; Providers differ in what they do with a system prompt -- some
   ;; local backends drop it outright -- and a model that never saw the
   ;; bucket names answers with its own vocabulary, which parses as
   ;; nothing.  Repeating them costs a few dozen tokens.
   (cmacs-brigade-genmail--triage-system-prompt) "\n\n"
   (format "Classify %s.\n\n"
           (if (= 1 (length msgs)) "this message"
             (format "these %d messages" (length msgs))))
   (mapconcat
    (lambda (pair)
      (let* ((n (car pair))
             (m (cdr pair))
             ;; The *readable* text, not the raw file.  Mail that arrives
             ;; now is HTML, so a raw excerpt is 400 characters of
             ;; doctype and quoted-printable -- no signal to classify on,
             ;; and the model pays for reading it.
             (body (or (ignore-errors
                         (cmacs-brigade-genmail-message-text
                          (plist-get m :path)))
                       "")))
        (format "%d. From: %s\n   Subject: %s\n   Body: %s\n"
                n
                (cmacs-brigade-genmail--format-addr (car (plist-get m :from)))
                (or (plist-get m :subject) "(no subject)")
                (string-trim
                 (replace-regexp-in-string
                  "[ \t\n]+" " "
                  (truncate-string-to-width (string-trim body) 400))))))
    (let ((n 0)) (mapcar (lambda (m) (cons (cl-incf n) m)) msgs))
    "\n")
   ;; A filled-in template, not a described format.  A small local model
   ;; asked to "answer NUMBER BUCKET" writes an essay with a summary
   ;; table; asked to complete these exact lines it usually completes
   ;; them.  The parser still assumes it did not.
   "\nAnswer template -- replace each BUCKET and ACTION, output these"
   "\nlines only:\n"
   (mapconcat (lambda (n) (format "%d BUCKET ACTION" n))
              (number-sequence 1 (length msgs)) "\n")
   "\n"))

(defun cmacs-brigade-genmail--parse-verdicts (text count)
  "Parse TEXT into a vector of COUNT (BUCKET . ACTION) conses.

A slot is nil where no bucket was answered; ACTION is nil when only
the bucket was.  Tolerant on purpose: a small local model will number
its lines \"1.\", \"1)\" or \"1 -\", and will occasionally add a
sentence nobody asked for.  Anything that is not a known bucket or
action is left nil rather than guessed at."
  (let ((out (make-vector count nil)))
    ;; First pass: the format that was asked for -- "N BUCKET ACTION".
    (dolist (line (split-string (or text "") "\n" t))
      (when (string-match
             (concat "\\`[^0-9]*\\([0-9]+\\)[.):[:space:]-]+\\**\\([a-zA-Z-]+\\)"
                     "\\(?:[[:space:],*]+\\([a-zA-Z-]+\\)\\)?")
             line)
        (let ((n (string-to-number (match-string 1 line)))
              (bucket (intern (downcase (match-string 2 line))))
              (action (and (match-string 3 line)
                           (intern (downcase (match-string 3 line))))))
          (when (and (>= n 1) (<= n count)
                     (memq bucket cmacs-brigade-genmail-buckets))
            (aset out (1- n)
                  (cons bucket (and (memq action cmacs-brigade-genmail-actions)
                                    action)))))))
    ;; Second pass: the answer was prose.  Split it at the numbering and
    ;; take the first bucket and action words named in each message's own
    ;; section -- a model that wrote a paragraph about message 2 usually
    ;; still says "act-now" somewhere inside it.
    (unless (cl-every #'identity (append out nil))
      (cmacs-brigade-genmail--scan-sections text count out))
    out))

(defun cmacs-brigade-genmail--parse-buckets (text count)
  "Parse TEXT into a vector of COUNT bucket symbols, nil where unanswered.
The bucket half of `cmacs-brigade-genmail--parse-verdicts'."
  (vconcat (mapcar #'car-safe
                   (cmacs-brigade-genmail--parse-verdicts text count))))

(defun cmacs-brigade-genmail--scan-sections (text count out)
  "Fill unanswered slots of OUT by scanning TEXT's numbered sections.

COUNT is how many messages were asked about; OUT holds (BUCKET . ACTION)
conses.  Modifies and returns OUT."
  (let ((marks nil))
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      ;; Where each message's section starts.
      (while (re-search-forward "^[^0-9\n]\\{0,8\\}\\([0-9]+\\)[.):]" nil t)
        (let ((n (string-to-number (match-string 1))))
          (when (and (>= n 1) (<= n count) (null (alist-get n marks)))
            (push (cons n (point)) marks))))
      (setq marks (sort (nreverse marks) (lambda (a b) (< (cdr a) (cdr b)))))
      (let ((rest marks))
        (while rest
          (let* ((this (car rest))
                 (end (if (cdr rest) (cdr (cadr rest)) (point-max)))
                 (n (car this)))
            (when (null (aref out (1- n)))
              (goto-char (cdr this))
              (let ((bucket nil) (action nil))
                (while (and (not bucket)
                            (re-search-forward
                             "\\_<\\(act-now\\|waiting-on-me\\|newsletter\\|receipt\\|reply\\|noise\\|fyi\\)\\_>"
                             end t))
                  (setq bucket (intern (downcase (match-string 1)))))
                (when bucket
                  (save-excursion
                    (while (and (not action)
                                (re-search-forward
                                 "\\_<\\(trash\\|archive\\|todo\\|triage\\)\\_>"
                                 end t))
                      (setq action (intern (downcase (match-string 1))))))
                  (aset out (1- n) (cons bucket action))))))
          (setq rest (cdr rest))))))
  out)

;;;###autoload
(defun cmacs-brigade-genmail-triage (&optional limit force)
  "Classify unread inbox mail and write an org report.  Returns the file.

Scoped by `cmacs-brigade-genmail-inbox-query'.

The deterministic rules run first.  Whatever they cannot decide goes to
`cmacs-brigade-genmail-triage-model' in a single batched call, which
runs *asynchronously* -- the report is written when the model answers,
which under `--gowl' is the difference between a pause and a frozen
desktop.  The returned path is where that report will land.

With FORCE (interactively, a prefix argument) every message goes to the
model and the rules only advise.  On a normal morning the rules decide
most of the mail and the model is never called at all, which is correct
but indistinguishable from a broken model pass -- this is how you tell
the two apart, and how you second-guess a rule you think is wrong."
  (interactive (list nil current-prefix-arg))
  (unless (cmacs-brigade-genmail-available-p)
    (user-error "cmacs-brigade: mu is not installed"))
  (when cmacs-brigade-genmail--inflight
    (user-error "cmacs-brigade: a triage model pass is already running"))
  (let* ((msgs (cmacs-brigade-genmail-query
                (cmacs-brigade-genmail--unread-query)
                (or limit cmacs-brigade-genmail-max-triage)))
         (interactive-p (called-interactively-p 'any))
         (classified nil)
         (pending nil))
    (dolist (m msgs)
      (let* ((cheap (and (not force)
                         (cmacs-brigade-genmail--obviously-automated-p m)))
             (entry (append m (list :bucket (or cheap 'pending)
                                    :by (if cheap 'rule 'pending)
                                    :action (and cheap
                                                 (cmacs-brigade-genmail--default-action
                                                  cheap))))))
        (unless cheap (push entry pending))
        (push entry classified)))
    (setq classified (nreverse classified)
          pending (nreverse pending))
    (if (and pending
             cmacs-brigade-genmail-use-model
             (cmacs-brigade-genmail--ai-available-p))
        ;; Write and open what the rules already know *now*, and let the
        ;; model's answer rewrite the file underneath.  Waiting for a
        ;; local model before showing anything means staring at a
        ;; minibuffer message for a minute while the work that was
        ;; already done sits unwritten.
        (progn
          (cmacs-brigade-genmail--write-triage classified)
          (when interactive-p
            (find-file (cmacs-brigade-genmail--triage-file))
            (message "cmacs-brigade: %d by rule; asking %s about %d more"
                     (- (length classified) (length pending))
                     cmacs-brigade-genmail-triage-model (length pending)))
          (cmacs-brigade-genmail--triage-model-pass classified pending
                                                    interactive-p))
      ;; Nothing to ask about, or nobody to ask: the rules already
      ;; decided everything that is going to be decided.
      (cmacs-brigade-genmail--settle-pending pending)
      (cmacs-brigade-genmail--triage-finish classified interactive-p))))

(defun cmacs-brigade-genmail--settle-pending (pending)
  "File anything still PENDING, honestly labelled.

A message being re-judged carries its previous verdict in
`:prior-bucket', and when the model fails to answer that verdict comes
back -- the old answer was at least an answer.  A message that never
had one is filed under `reply', recorded as unclassified: the safe
bucket, and nobody decided this one."
  (dolist (m pending)
    (when (eq 'pending (plist-get m :by))
      (cmacs-brigade-genmail--restore-or-default m))))

(defun cmacs-brigade-genmail--restore-or-default (m)
  "Give M back its prior verdict, or file it under `reply' unclassified.

The recommended action comes back with it; a message nobody decided
recommends `triage', which is what unclassified means."
  (let ((prior (plist-get m :prior-bucket)))
    (if prior
        (progn (plist-put m :bucket prior)
               (plist-put m :by (or (plist-get m :prior-by) 'unclassified))
               (plist-put m :action (or (plist-get m :prior-action)
                                        (cmacs-brigade-genmail--default-action
                                         prior))))
      (plist-put m :bucket 'reply)
      (plist-put m :by 'unclassified)
      (plist-put m :action 'triage))))

(defun cmacs-brigade-genmail--triage-model-pass (classified pending interactive-p
                                                            &optional file)
  "Ask the model about PENDING, then finish CLASSIFIED into FILE.

One call for the whole batch rather than one per message: a dozen round
trips to a local model costs a dozen model loads' worth of latency for
an answer that fits in one prompt.  Returns the report path, which is
written from the stream callback.  FILE defaults to today's report."
  (let* ((split (cmacs-brigade-genmail--split-model
                 cmacs-brigade-genmail-triage-model))
         (answer "")
         (pair nil)
         (timer nil)
         (finished nil)
         (finish nil))
    (setq cmacs-brigade-genmail--inflight t)
    ;; One exit point, run once.  The stream and the timeout race each
    ;; other by construction, and finishing twice would write the report
    ;; twice and run the hook twice.
    (setq finish
          (lambda (failure)
            (unless finished
              (setq finished t)
              (setq cmacs-brigade-genmail--inflight nil)
              (when timer (cancel-timer timer) (setq timer nil))
              (ignore-errors (cmacs-ai-free-session pair))
              (if failure
                  (progn
                    ;; A model that did not answer must not become a
                    ;; report that merely looks classified.
                    (message "cmacs-brigade: triage model %s; rules only"
                             failure)
                    (cmacs-brigade-genmail--settle-pending pending))
                (cmacs-brigade-genmail--apply-buckets pending answer))
              (cmacs-brigade-genmail--triage-finish classified
                                                    interactive-p file))))
    (condition-case err
        (progn
          (setq pair (cmacs-ai-make-session
                      (car split) (cdr split)
                      (cmacs-brigade-genmail--triage-system-prompt)))
          (message "cmacs-brigade: triage asking %s about %d message(s)..."
                   cmacs-brigade-genmail-triage-model (length pending))
          (when cmacs-brigade-genmail-triage-timeout
            (setq timer
                  (run-at-time cmacs-brigade-genmail-triage-timeout nil
                               (lambda ()
                                 (ignore-errors
                                   (cmacs-ai-chat-cancel (cdr pair)))
                                 (funcall finish "timed out")))))
          (cmacs-ai-chat-stream
           (cdr pair)
           (cmacs-brigade-genmail--triage-prompt pending)
           (lambda (payload)
             (pcase (car-safe payload)
               (:delta (setq answer (concat answer (or (cadr payload) ""))))
               (:end
                (let ((final (plist-get (cdr payload) :text)))
                  (when (and final (> (length (string-trim final))
                                      (length (string-trim answer))))
                    (setq answer final)))
                (funcall finish nil))
               (:error
                (funcall finish (format "failed (%s)"
                                        (or (cadr payload) "stream error"))))))))
      (error
       (funcall finish (format "unavailable (%s)" (error-message-string err)))))
    (or file (cmacs-brigade-genmail--triage-file))))

(defun cmacs-brigade-genmail--apply-buckets (pending answer)
  "Set bucket and action on each of PENDING from the model's ANSWER.

A slot the model left unanswered falls back the same way a failed call
does: the prior verdict when there was one, else `reply' recorded as
unclassified.  A bucket with no action gets the bucket's default."
  (let ((verdicts (cmacs-brigade-genmail--parse-verdicts
                   answer (length pending)))
        (n 0))
    (dolist (m pending)
      (let* ((v (aref verdicts n))
             (bucket (car-safe v)))
        (if bucket
            (progn (plist-put m :bucket bucket)
                   (plist-put m :by 'model)
                   (plist-put m :action
                              (or (cdr v)
                                  (cmacs-brigade-genmail--default-action
                                   bucket))))
          (cmacs-brigade-genmail--restore-or-default m)))
      (cl-incf n))))

(defun cmacs-brigade-genmail--refresh-report (file)
  "Re-read FILE in whatever buffer is visiting it.  Returns that buffer.

Point is kept, so an answer landing while you are reading the report
does not throw away where you were.  A buffer with unsaved edits is
left alone -- your notes on the mail outrank our rewrite."
  (let ((buf (find-buffer-visiting file)))
    (when buf
      (with-current-buffer buf
        (if (buffer-modified-p)
            (message
             "cmacs-brigade: triage updated %s, but this buffer has edits"
             (file-name-nondirectory file))
          (let ((pos (point)))
            (revert-buffer t t t)
            (goto-char (min pos (point-max)))))))
    buf))

(defun cmacs-brigade-genmail--triage-finish (classified interactive-p
                                                        &optional file)
  "Write CLASSIFIED into FILE, run the hook, and report.  Returns the path.
FILE defaults to today's report."
  (let* ((file (cmacs-brigade-genmail--write-triage classified file))
         ;; The report may already be on screen from the rules pass; in
         ;; that case update it in place rather than opening a second
         ;; window on the same file.
         (shown (cmacs-brigade-genmail--refresh-report file))
         (by-rule (cl-count 'rule classified
                            :key (lambda (m) (plist-get m :by))))
         (by-model (cl-count 'model classified
                             :key (lambda (m) (plist-get m :by)))))
    (run-hook-with-args 'cmacs-brigade-genmail-triaged-functions classified)
    (when interactive-p
      (message "cmacs-brigade: triaged %d message(s), %d by rule, %d by model -> %s"
               (length classified) by-rule by-model file)
      (unless shown (find-file file)))
    file))

(defvar cmacs-brigade-genmail-triaged-functions nil
  "Abnormal hook run with the classified message list after triage.")

(defun cmacs-brigade-genmail--write-triage (messages &optional file)
  "Write MESSAGES as an org report to FILE and return the path.
FILE defaults to today's report, so the path `triage' promised before
the model answered is the path that gets written."
  (let ((file (or file (cmacs-brigade-genmail--triage-file))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert "#+title: Mail triage " (format-time-string "%F") "\n"
              "#+created: " (format-time-string "[%F %a %H:%M]") "\n\n")
      ;; Say so when the file is not finished, rather than letting a
      ;; half-written report look like a finished one.
      (let ((waiting (cl-count 'pending messages
                               :key (lambda (m) (plist-get m :by)))))
        (when (> waiting 0)
          (insert (format
                   "Waiting on %s for %d message(s).  This file rewrites\n"
                   cmacs-brigade-genmail-triage-model waiting)
                  "itself when the answer lands; everything below is what\n"
                  "the rules already decided.\n\n")))
      ;; The second-opinion button: everything back to the model, the
      ;; rules only advising.  Written even when the model pass is off
      ;; -- following it then says why nothing happened, which beats a
      ;; report that silently has no way to disagree with a rule.
      (when messages
        (insert "[[cmacs-genmail:retriage:all]"
                "[Ask the model to reclassify everything]]\n\n"))
      ;; `pending' is a report-only bucket -- it is deliberately not in
      ;; `cmacs-brigade-genmail-buckets', so a model cannot answer with it.
      (dolist (bucket (cons 'pending cmacs-brigade-genmail-buckets))
        (let ((in-bucket (cl-remove-if-not
                          (lambda (m) (eq bucket (plist-get m :bucket)))
                          messages)))
          (when in-bucket
            (insert (format "* %s (%d)\n" bucket (length in-bucket)))
            ;; The same button scoped to one section, for when a rule
            ;; got a whole class of mail wrong.  Not on `pending': those
            ;; are already on their way to the model.
            (unless (eq bucket 'pending)
              (insert (format
                       "  [[cmacs-genmail:retriage:bucket:%s][ask the model about these]]\n"
                       bucket)))
            (dolist (m in-bucket)
              (insert (format "** %s\n" (or (plist-get m :subject) "(no subject)")))
              (insert "   :PROPERTIES:\n")
              (insert (format "   :FROM: %s\n"
                              (cmacs-brigade-genmail--format-addr
                               (car (plist-get m :from)))))
              (when (plist-get m :message-id)
                (insert (format "   :MSGID: %s\n" (plist-get m :message-id))))
              (insert (format "   :BY: %s\n" (plist-get m :by)))
              (when (and (plist-get m :action) (not (eq bucket 'pending)))
                (insert (format "   :SUGGEST: %s\n" (plist-get m :action))))
              (when (plist-get m :acted)
                (insert (format "   :ACTED: %s\n" (plist-get m :acted))))
              (insert "   :END:\n")
              ;; A link back into mu4e, so the report is a place to act
              ;; from rather than a thing to read and then go looking --
              ;; with the second opinion and the disposal actions beside
              ;; it.  A message already acted on keeps only its record:
              ;; the buttons' work is done.
              (when (plist-get m :message-id)
                (let ((id (plist-get m :message-id)))
                  (insert (format "   [[mu4e:msgid:%s][open]]" id))
                  (cond
                   ((plist-get m :acted)
                    (insert (format "  done: %s" (plist-get m :acted))))
                   ((not (eq bucket 'pending))
                    (insert (format "  [[cmacs-genmail:retriage:msgid:%s][reclassify]]" id))
                    (insert (format "  [[cmacs-genmail:trash:%s][trash]]" id))
                    (insert (format "  [[cmacs-genmail:archive:%s][archive]]" id))
                    (insert (format "  [[cmacs-genmail:todo:%s][todo]]" id))))
                  (insert "\n")
                  (when (and (plist-get m :action)
                             (not (plist-get m :acted))
                             (not (eq bucket 'pending)))
                    (insert (format "   *suggested action:* _%s_\n"
                                    (plist-get m :action)))))))))))
    file))

;;;; Second opinions
;;
;; The report is the state.  Reclassifying re-reads what the report
;; says rather than re-querying unread mail, so a message you read
;; since triage is still re-judged, and one that arrived since is not
;; silently pulled in.  This is what the report's own buttons dispatch
;; to, and it is how you overrule a rule without editing any code.

(defun cmacs-brigade-genmail--context-report ()
  "Return the report the current buffer is reading, else today's."
  (or (and buffer-file-name
           (string-match-p "_triage\\.org\\'" buffer-file-name)
           buffer-file-name)
      (cmacs-brigade-genmail--triage-file)))

(defun cmacs-brigade-genmail--report-entries (file)
  "Parse the triage report at FILE back into classified message plists.

Each entry is re-fetched from mu by message id so the model prompt can
read the body; a message mu no longer finds keeps what the report knew,
which is enough to classify on sender and subject."
  (when (file-readable-p file)
    (let (bucket entry out)
      (with-temp-buffer
        (insert-file-contents file)
        (dolist (line (split-string (buffer-string) "\n"))
          (cond
           ((string-match "\\`\\* \\([a-z-]+\\) (" line)
            (setq bucket (intern (match-string 1 line))))
           ((string-match "\\`\\*\\* \\(.*\\)\\'" line)
            (when entry (push entry out))
            (setq entry (list :subject (match-string 1 line)
                              :bucket bucket :by 'unclassified)))
           ((and entry (string-match "\\`[ \t]*:FROM: \\(.*\\)\\'" line))
            ;; A bare string: the address accessors accept it, and
            ;; re-parsing "Name <email>" would be a second parser for a
            ;; format this file itself wrote.
            (plist-put entry :from (list (match-string 1 line))))
           ((and entry (string-match "\\`[ \t]*:MSGID: \\(.*\\)\\'" line))
            (plist-put entry :message-id (match-string 1 line)))
           ((and entry (string-match "\\`[ \t]*:BY: \\([a-z-]+\\)\\'" line))
            (plist-put entry :by (intern (match-string 1 line))))
           ((and entry (string-match "\\`[ \t]*:SUGGEST: \\([a-z-]+\\)\\'" line))
            (plist-put entry :action (intern (match-string 1 line))))
           ((and entry (string-match "\\`[ \t]*:ACTED: \\([a-z-]+\\)\\'" line))
            (plist-put entry :acted (intern (match-string 1 line)))))))
      (when entry (push entry out))
      (mapcar
       (lambda (e)
         (let* ((id (plist-get e :message-id))
                (m (and id (ignore-errors
                             (car (cmacs-brigade-genmail-query
                                   (format "msgid:%s" id) 1))))))
           (if m
               (append m (list :bucket (plist-get e :bucket)
                               :by (plist-get e :by)
                               :action (plist-get e :action)
                               :acted (plist-get e :acted)))
             e)))
       (nreverse out)))))

;;;###autoload
(defun cmacs-brigade-genmail-reclassify (&optional selector file)
  "Send triage-report entries back to the model, whatever the rules said.

SELECTOR is `all', (bucket . NAME) for one section, or (msgid . ID) for
one message; interactively, everything.  FILE is the report to operate
on -- the one behind the current buffer when that is a triage report,
else today's.  Returns the report path, which rewrites itself when the
model answers, exactly like first-pass triage.

The model's answer replaces the rule's; a message the model still does
not decide keeps the verdict it had."
  (interactive (list 'all))
  (unless (cmacs-brigade-genmail-available-p)
    (user-error "cmacs-brigade: mu is not installed"))
  (when cmacs-brigade-genmail--inflight
    (user-error "cmacs-brigade: a triage model pass is already running"))
  (unless (and cmacs-brigade-genmail-use-model
               (cmacs-brigade-genmail--ai-available-p))
    (user-error
     "cmacs-brigade: no model to ask (check `cmacs-brigade-genmail-use-model')"))
  (let* ((selector (or selector 'all))
         (file (or file (cmacs-brigade-genmail--context-report)))
         (entries (cmacs-brigade-genmail--report-entries file))
         (pred (pcase selector
                 ('all (lambda (_) t))
                 (`(bucket . ,b) (lambda (e) (eq b (plist-get e :bucket))))
                 (`(msgid . ,id) (lambda (e)
                                   (equal id (plist-get e :message-id))))
                 (_ (user-error "cmacs-brigade: bad selector %S" selector))))
         (chosen nil))
    (unless entries
      (user-error "cmacs-brigade: no triage report at %s" file))
    (dolist (e entries)
      ;; An acted-on message is settled twice over -- it is not even in
      ;; the inbox any more -- so bucket-wide and report-wide selectors
      ;; step around it.
      (when (and (funcall pred e) (not (plist-get e :acted)))
        ;; Remember the standing verdict: a model that fails to answer
        ;; restores it, rather than downgrading a decided message to
        ;; the `reply' fallback.
        (plist-put e :prior-bucket (plist-get e :bucket))
        (plist-put e :prior-by (plist-get e :by))
        (plist-put e :prior-action (plist-get e :action))
        (plist-put e :bucket 'pending)
        (plist-put e :by 'pending)
        (push e chosen)))
    (setq chosen (nreverse chosen))
    (unless chosen
      (user-error "cmacs-brigade: nothing in the report matches %S" selector))
    ;; Show the pending state now, exactly like first-pass triage: the
    ;; wait is visible, and the report never claims more than it knows.
    (cmacs-brigade-genmail--write-triage entries file)
    (cmacs-brigade-genmail--refresh-report file)
    (message "cmacs-brigade: asking %s to reclassify %d message(s)..."
             cmacs-brigade-genmail-triage-model (length chosen))
    (cmacs-brigade-genmail--triage-model-pass entries chosen t file)))

;;;; Acting on a message
;;
;; The trash and archive buttons are mu4e's own mark-then-execute, one
;; click.  When mu4e is around the move goes through its server --
;; which is the only way to respect the user's folder functions, their
;; flag overrides, and the mbsync rename requirement all at once.  A
;; build with no mu4e falls back to moving the file by hand and
;; reindexing, which is what the server would have done.

(defvar cmacs-brigade-genmail--sync-timer nil
  "Debounce timer behind `cmacs-brigade-genmail-sync-after-move'.")

(defun cmacs-brigade-genmail--target-folder (kind msg)
  "Return the maildir a KIND move (`trash' or `archive') sends MSG to."
  (let ((custom (if (eq kind 'trash) cmacs-brigade-genmail-trash-folder
                  cmacs-brigade-genmail-archive-folder)))
    (or (if (functionp custom) (funcall custom msg) custom)
        (and (require 'mu4e nil t)
             (require 'mu4e-folders nil t)
             (ignore-errors
               (if (eq kind 'trash)
                   (mu4e-get-trash-folder msg)
                 (mu4e-get-refile-folder msg))))
        ;; mu4e loaded but its folder unset, or no mu4e at all: the
        ;; conventional names are wrong often enough that guessing a
        ;; move target is worse than asking.
        (user-error
         "cmacs-brigade: set `cmacs-brigade-genmail-%s-folder'"
         (if (eq kind 'trash) "trash" "archive")))))

(defun cmacs-brigade-genmail--move-message (msg folder flags)
  "Move MSG into FOLDER with FLAGS, preferring mu4e's server.

No filesystem fallback while mu4e is present: its server may hold the
xapian write lock, and moving files behind a live server means a CLI
reindex that cannot get the lock and an index that disagrees with the
disk."
  (if (and (require 'mu4e nil t)
           (require 'mu4e-server nil t)
           (fboundp 'mu4e--server-move))
      (progn
        ;; A background session, not a UI: loads the user's real config
        ;; (folders, rename-on-move) and starts the server.
        (unless (and (fboundp 'mu4e-running-p) (mu4e-running-p))
          (mu4e t))
        (mu4e--server-move (plist-get msg :message-id) folder flags
                           (bound-and-true-p mu4e-change-filenames-when-moving))
        (cmacs-brigade-genmail--schedule-sync))
    (cmacs-brigade-genmail--fs-move msg folder)))

(defun cmacs-brigade-genmail--schedule-sync ()
  "Push local moves to the mail server soon, once per burst of clicks."
  (when (and cmacs-brigade-genmail-sync-after-move
             (require 'mu4e-update nil t)
             (fboundp 'mu4e-update-mail-and-index))
    (when (timerp cmacs-brigade-genmail--sync-timer)
      (cancel-timer cmacs-brigade-genmail--sync-timer))
    (setq cmacs-brigade-genmail--sync-timer
          (run-at-time 5 nil
                       (lambda ()
                         (setq cmacs-brigade-genmail--sync-timer nil)
                         (ignore-errors
                           (mu4e-update-mail-and-index t)))))))

(defun cmacs-brigade-genmail--maildir-root (path maildir)
  "Return the store root, given a message PATH and its MAILDIR."
  (let* ((dir (directory-file-name (file-name-directory path)))
         (box (directory-file-name (file-name-directory dir))))
    (unless (string-suffix-p maildir box)
      (user-error "cmacs-brigade: %s is not under maildir %s" path maildir))
    (substring box 0 (- (length box) (length maildir)))))

(defun cmacs-brigade-genmail--fs-move (msg folder)
  "Move MSG's file into FOLDER by hand and reindex.  The no-mu4e path.

The file gets a fresh maildir basename, which is what mbsync needs to
see a move as a move; the flags suffix survives.  Returns the new
path."
  (let ((path (plist-get msg :path))
        (maildir (plist-get msg :maildir)))
    (unless (and path (file-exists-p path))
      (user-error "cmacs-brigade: no file on disk for this message"))
    (unless maildir
      (user-error "cmacs-brigade: mu reported no maildir for this message"))
    (let* ((root (cmacs-brigade-genmail--maildir-root path maildir))
           (target-dir (expand-file-name
                        (concat (substring folder 1) "/cur/") root)))
      (unless (file-directory-p target-dir)
        (user-error "cmacs-brigade: no maildir %s under %s (mu mkdir first)"
                    folder root))
      (let* ((old (file-name-nondirectory path))
             (flags (if (string-match ":2,\\([A-Za-z]*\\)\\'" old)
                        (match-string 1 old) ""))
             (target (expand-file-name
                      (format "%d.%06d.%s:2,%s"
                              (time-convert nil 'integer) (random 1000000)
                              (system-name) flags)
                      target-dir)))
        (rename-file path target)
        (cmacs-brigade-genmail--reindex)
        target))))

(defun cmacs-brigade-genmail--reindex ()
  "Update the mu index in the background.

Async on principle: `call-process' here would sit inside a click on an
org link, and under `--gowl' that is the compositor waiting on xapian."
  (make-process
   :name "genmail-mu-index"
   :command (list cmacs-brigade-genmail-mu-program "index" "--quiet")
   :noquery t
   :sentinel (lambda (proc _event)
               (unless (eq 0 (process-exit-status proc))
                 (message "cmacs-brigade: mu index exited %s (is a mu server running?)"
                          (process-exit-status proc))))))

(defun cmacs-brigade-genmail--mark-acted (msgid acted file)
  "Record ACTED against MSGID in the report at FILE, best effort.

Best effort because the real action already happened; a report that
missed the memo costs a stale pair of buttons, not a lost message."
  (let* ((entries (cmacs-brigade-genmail--report-entries file))
         (e (cl-find msgid entries
                     :key (lambda (x) (plist-get x :message-id))
                     :test #'equal)))
    (when e
      (plist-put e :acted acted)
      (cmacs-brigade-genmail--write-triage entries file)
      (cmacs-brigade-genmail--refresh-report file))))

(defun cmacs-brigade-genmail--entry-for (msgid file)
  "Return the freshest message plist for MSGID: mu first, then FILE."
  (or (ignore-errors
        (car (cmacs-brigade-genmail-query (format "msgid:%s" msgid) 1)))
      (cl-find msgid (cmacs-brigade-genmail--report-entries file)
               :key (lambda (x) (plist-get x :message-id))
               :test #'equal)
      (user-error "cmacs-brigade: no message %s" msgid)))

(defun cmacs-brigade-genmail--move-and-record (msgid kind file)
  "Move MSGID per KIND (`trash' or `archive') and update the report."
  (let* ((file (or file (cmacs-brigade-genmail--context-report)))
         (msg (cmacs-brigade-genmail--entry-for msgid file))
         (subject (or (plist-get msg :subject) "(no subject)"))
         (folder (cmacs-brigade-genmail--target-folder kind msg))
         (flags (if (eq kind 'trash) cmacs-brigade-genmail-trash-flags "-N")))
    (when (and cmacs-brigade-genmail-confirm-moves
               (not (y-or-n-p (format "%s \"%s\" -> %s? "
                                      (capitalize (symbol-name kind))
                                      subject folder))))
      (user-error "cmacs-brigade: cancelled"))
    (cmacs-brigade-genmail--move-message msg folder flags)
    (cmacs-brigade-genmail--mark-acted
     msgid (if (eq kind 'trash) 'trashed 'archived) file)
    (message "cmacs-brigade: %s -> %s" subject folder)))

;;;###autoload
(defun cmacs-brigade-genmail-trash-message (msgid &optional file)
  "Move MSGID to the trash folder -- mu4e's d-then-x, one click.

Never a delete: the message moves to a maildir it can be fished back
out of, and `cmacs-brigade-genmail-confirm-moves' asks first."
  (interactive "sMessage id: ")
  (cmacs-brigade-genmail--move-and-record msgid 'trash file))

;;;###autoload
(defun cmacs-brigade-genmail-archive-message (msgid &optional file)
  "Move MSGID to the archive folder -- mu4e's r-then-x, one click."
  (interactive "sMessage id: ")
  (cmacs-brigade-genmail--move-and-record msgid 'archive file))

(defun cmacs-brigade-genmail--todo-file ()
  "Return the file the todo button appends to.

The org-roam daily when org-roam's dailies are configured -- that is
where the user's own capture flow logs the day's todos -- else the
briefing's daily-note function."
  (or (and cmacs-brigade-genmail-todo-file-function
           (funcall cmacs-brigade-genmail-todo-file-function))
      (and (boundp 'org-roam-directory) (boundp 'org-roam-dailies-directory)
           (expand-file-name
            (format-time-string "%Y-%m-%d.org")
            (expand-file-name (symbol-value 'org-roam-dailies-directory)
                              (symbol-value 'org-roam-directory))))
      (and cmacs-brigade-genmail-daily-note-function
           (funcall cmacs-brigade-genmail-daily-note-function))
      (user-error
       "cmacs-brigade: set `cmacs-brigade-genmail-todo-file-function'")))

;;;###autoload
(defun cmacs-brigade-genmail-log-todo (msgid &optional file)
  "Append a TODO for MSGID to the day's todo file.

The entry carries a link back to the mail, so working the todo starts
from the message rather than from a memory of it.  Appended, never
inserted into someone's own outline structure."
  (interactive "sMessage id: ")
  (let* ((file (or file (cmacs-brigade-genmail--context-report)))
         (msg (cmacs-brigade-genmail--entry-for msgid file))
         (subject (or (plist-get msg :subject) "(no subject)"))
         (from (cmacs-brigade-genmail--format-addr (car (plist-get msg :from))))
         (todo-file (cmacs-brigade-genmail--todo-file)))
    (with-current-buffer (find-file-noselect todo-file)
      (when (= (point-min) (point-max))
        ;; A file this code created gets at least a title; the user's
        ;; own daily template applies when *they* create the day.
        (insert (format-time-string "#+title: %Y-%m-%d\n\n")))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* TODO %s\n:PROPERTIES:\n:CREATED: %s\n:END:\n[[mu4e:msgid:%s][mail]] from %s\n"
                      subject (format-time-string "[%F %a %H:%M]") msgid from))
      (save-buffer))
    (cmacs-brigade-genmail--mark-acted msgid 'todo file)
    (message "cmacs-brigade: TODO logged to %s"
             (file-name-nondirectory todo-file))))

(defun cmacs-brigade-genmail--plist-address-p (a)
  "Non-nil when A is mu's modern (:email ... :name ...) form.

Decided once, here, rather than re-tested in each accessor: a plist that
happens to carry no :name would otherwise fall through to the old-style
cons branch and yield the keyword `:email' as somebody's name."
  (and (proper-list-p a) (plist-member a :email) t))

(defun cmacs-brigade-genmail--address (a)
  "Return the bare email address from A, whatever shape mu gave it.

Modern mu returns a plist per address; older versions returned a
\(NAME . EMAIL) cons.  Both appear in the wild depending on which mu
indexed the store, so both are handled here rather than at each of the
half-dozen call sites."
  (cond ((null a) nil)
        ((stringp a) a)
        ((cmacs-brigade-genmail--plist-address-p a) (plist-get a :email))
        ((consp a) (cdr a))
        (t nil)))

(defun cmacs-brigade-genmail--addr-name (a)
  "Return the display name from A, or nil."
  (cond ((null a) nil)
        ((stringp a) nil)
        ((cmacs-brigade-genmail--plist-address-p a) (plist-get a :name))
        ((consp a) (car a))
        (t nil)))

(defun cmacs-brigade-genmail--format-addr (a)
  "Render A as \"Name <email>\" for display."
  (let ((email (cmacs-brigade-genmail--address a))
        (name (cmacs-brigade-genmail--addr-name a)))
    (cond ((and name email) (format "%s <%s>" name email))
          (email email)
          (t "?"))))


;;;; Drafting

;;;###autoload
(defun cmacs-brigade-genmail-draft (msgid)
  "Draft a reply to MSGID in your own voice, into a compose buffer.

Never writes to the Drafts maildir and never sends.  Composing through
mu4e means your signature, your send path and your encryption all apply,
which a hand-written file in Drafts would quietly bypass."
  (interactive "sMessage id: ")
  (unless (cmacs-brigade-genmail-available-p)
    (user-error "cmacs-brigade: mu is not installed"))
  (let* ((msgs (cmacs-brigade-genmail-query (format "msgid:%s" msgid) 1))
         (msg (car msgs)))
    (unless msg (user-error "cmacs-brigade: no message %s" msgid))
    (let* ((addr (or (cmacs-brigade-genmail--address
                      (car (plist-get msg :from))) ""))
           (bucket (cmacs-brigade-genmail--bucket-for addr))
           (voice (cmacs-brigade-genmail-voice bucket))
           (body (cmacs-brigade-genmail-body (plist-get msg :path)))
           (prompt (cmacs-brigade-genmail--draft-prompt msg body voice)))
      (if (fboundp 'mu4e-compose-reply)
          (progn (funcall 'mu4e-compose-reply)
                 (message "cmacs-brigade: reply drafted; review before sending"))
        ;; Without mu4e, hand back the prompt rather than pretending.
        (with-current-buffer (get-buffer-create "*genmail draft prompt*")
          (erase-buffer)
          (insert prompt)
          (display-buffer (current-buffer))))
      prompt)))

(defun cmacs-brigade-genmail--draft-prompt (msg body voice)
  "Build the drafting prompt for MSG."
  (let ((features (plist-get voice :features))
        (exemplars (seq-take (or (plist-get voice :exemplars) '()) 3)))
    (concat
     "Draft a reply in the user's own voice.\n\n"
     (when features
       (format "Their style, measured over %s of their sent messages:\n\
  typical length: %s words (median %s)\n\
  sentence length: %s words\n\
  opens with a greeting: %.0f%% of the time\n\
  signs off: %.0f%% of the time\n\
  exclamation marks per message: %.1f\n\n"
               (plist-get features :samples)
               (plist-get features :mean-words)
               (plist-get features :median-words)
               (plist-get features :mean-sentence-words)
               (* 100 (plist-get features :greeting-rate))
               (* 100 (plist-get features :signoff-rate))
               (plist-get features :exclamations-per-mail)))
     (when exemplars
       (concat "Examples of how they actually write:\n\n"
               (mapconcat (lambda (e) (concat "---\n" (string-trim e) "\n"))
                          exemplars "")
               "\n"))
     ;; The point of the whole feature: what they already told this
     ;; person, which they will not remember and the model can find.
     (let ((context (cmacs-brigade-genmail--memory-context msg)))
       (when context (concat "Relevant history from their own notes:\n\n"
                             context "\n\n")))
     "The message to reply to:\n\n"
     (format "From: %s\nSubject: %s\n\n%s\n"
             (cmacs-brigade-genmail--format-addr (car (plist-get msg :from)))
             (or (plist-get msg :subject) "")
             (or body "")))))

(defun cmacs-brigade-genmail--memory-context (msg)
  "Search the memory index for material about MSG's sender and subject."
  (when (and (fboundp 'cmacs-brigade-memory-search)
             (boundp 'cmacs-brigade-memory-enabled)
             cmacs-brigade-memory-enabled)
    (ignore-errors
      (let* ((from (cmacs-brigade-genmail--format-addr
                    (car (plist-get msg :from))))
             (hits (cmacs-brigade-memory-search
                    (format "%s %s" from (or (plist-get msg :subject) "")) 3)))
        (when hits
          (mapconcat (lambda (h) (format "- %s: %s" (plist-get h :heading)
                                         (truncate-string-to-width
                                          (plist-get h :text) 300)))
                     hits "\n"))))))


;;;; Briefing

;;;###autoload
(defun cmacs-brigade-genmail-briefing ()
  "Assemble a morning briefing and append it to today's note."
  (interactive)
  (let* ((unread (ignore-errors
                   (cmacs-brigade-genmail-query
                    (cmacs-brigade-genmail--unread-query) 100)))
         (text (cmacs-brigade-genmail--briefing-text unread))
         (note (and cmacs-brigade-genmail-daily-note-function
                    (funcall cmacs-brigade-genmail-daily-note-function))))
    (if (not note)
        (with-current-buffer (get-buffer-create "*genmail briefing*")
          (erase-buffer) (insert text) (display-buffer (current-buffer)))
      ;; Appended, never written over: daily notes are handwritten, and
      ;; clobbering someone's own writing to make room for a summary
      ;; would be indefensible.
      (with-current-buffer (find-file-noselect note)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert text)
        (save-buffer)))
    text))

(defun cmacs-brigade-genmail--briefing-text (unread)
  (let ((buckets (make-hash-table :test 'eq)))
    (dolist (m unread)
      (let ((b (or (cmacs-brigade-genmail--obviously-automated-p m) 'reply)))
        (puthash b (1+ (gethash b buckets 0)) buckets)))
    (concat "\n* Briefing " (format-time-string "%F %H:%M") "\n"
            (format "  %d unread in the inbox\n" (length unread))
            (let (lines)
              (maphash (lambda (k v) (push (format "  - %s: %d\n" k v) lines))
                       buckets)
              (apply #'concat (nreverse lines))))))


;;;; Tools

(cmacs-brigade-deftool mail-search
  "Search the user's mail.  Takes a mu query such as
\"from:alice AND subject:invoice\" or \"flag:unread\"."
  ((query string "A mu query")
   (limit integer "How many results" :optional t :default 20))
  :group 'mail
  (if (not (cmacs-brigade-genmail-available-p))
      "Error: mu is not installed."
    (let ((msgs (cmacs-brigade-genmail-query query (or limit 20))))
      (if (null msgs) "No matching mail."
        (mapconcat
         (lambda (m)
           (format "- %s | %s | %s"
                   (cmacs-brigade-genmail--format-addr (car (plist-get m :from)))
                   (or (plist-get m :subject) "(no subject)")
                   (or (plist-get m :message-id) "")))
         msgs "\n")))))

(cmacs-brigade-deftool mail-read
  "Read one message in full, by its message id as reported by
mail_search."
  ((msgid string "The message id"))
  :group 'mail
  (let* ((msgs (cmacs-brigade-genmail-query (format "msgid:%s" msgid) 1))
         (m (car msgs)))
    (if (null m) (format "Error: no message %s" msgid)
      (format "From: %s\nSubject: %s\n\n%s"
              (cmacs-brigade-genmail--format-addr (car (plist-get m :from)))
              (or (plist-get m :subject) "")
              (or (cmacs-brigade-genmail-body (plist-get m :path)) "")))))

(provide 'cmacs-brigade-genmail)

;;; cmacs-brigade-genmail.el ends here
