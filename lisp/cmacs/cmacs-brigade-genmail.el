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

(defcustom cmacs-brigade-genmail-triage-model "ollama/gpt-oss:20b"
  "Model used for triage.

A local model by default.  Triage runs over every unread message every
morning, and paying a frontier model to sort mail is a poor trade when
the task is mostly pattern recognition."
  :type 'string
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


;;;; Triage

(defun cmacs-brigade-genmail--obviously-automated-p (msg)
  "Return a bucket symbol when MSG can be classified with no model.

A List-Unsubscribe header identifies a newsletter with certainty.
Spending a model call to reach the same answer less reliably would be
the most common thing this code does and the least useful."
  (let* ((addr (downcase (or (cmacs-brigade-genmail--address
                              (car (plist-get msg :from))) "")))
         (subject (or (plist-get msg :subject) "")))
    (cond
     ((plist-get msg :list) 'newsletter)
     ;; Bulk senders that set neither header still announce themselves
     ;; in the From address often enough to be worth a rule.
     ((string-match-p "newsletter\\|digest\\|@\\(news\\|mail\\|email\\)\\." addr)
      'newsletter)
     ((string-match-p "noreply\\|no-reply\\|donotreply" addr) 'noise)
     ((string-match-p
       "\\(receipt\\|invoice\\|your order\\|order .* confirmed\\|payment \\(received\\|due\\)\\|shipped\\)"
       (downcase subject))
      'receipt)
     (t nil))))

;;;###autoload
(defun cmacs-brigade-genmail-triage (&optional limit)
  "Classify unread mail and write an org report.  Returns the file."
  (interactive)
  (unless (cmacs-brigade-genmail-available-p)
    (user-error "cmacs-brigade: mu is not installed"))
  (let* ((msgs (cmacs-brigade-genmail-query
                "flag:unread AND NOT maildir:/Spam"
                (or limit cmacs-brigade-genmail-max-triage)))
         (classified nil))
    (dolist (m msgs)
      (let ((cheap (cmacs-brigade-genmail--obviously-automated-p m)))
        (push (append m (list :bucket (or cheap 'reply)
                              :by (if cheap 'rule 'model)))
              classified)))
    (setq classified (nreverse classified))
    (let ((file (cmacs-brigade-genmail--write-triage classified)))
      (run-hook-with-args 'cmacs-brigade-genmail-triaged-functions classified)
      (when (called-interactively-p 'any)
        (message "cmacs-brigade: triaged %d message(s) -> %s"
                 (length classified) file)
        (find-file file))
      file)))

(defvar cmacs-brigade-genmail-triaged-functions nil
  "Abnormal hook run with the classified message list after triage.")

(defun cmacs-brigade-genmail--write-triage (messages)
  "Write MESSAGES as an org report and return the path."
  (let* ((dir (cmacs-brigade-genmail--output-dir))
         (file (expand-file-name
                (format-time-string "%Y-%m-%d_triage.org") dir)))
    (make-directory dir t)
    (with-temp-file file
      (insert "#+title: Mail triage " (format-time-string "%F") "\n"
              "#+created: " (format-time-string "[%F %a %H:%M]") "\n\n")
      (dolist (bucket '(act-now reply waiting-on-me fyi newsletter receipt noise))
        (let ((in-bucket (cl-remove-if-not
                          (lambda (m) (eq bucket (plist-get m :bucket)))
                          messages)))
          (when in-bucket
            (insert (format "* %s (%d)\n" bucket (length in-bucket)))
            (dolist (m in-bucket)
              (insert (format "** %s\n" (or (plist-get m :subject) "(no subject)")))
              (insert "   :PROPERTIES:\n")
              (insert (format "   :FROM: %s\n"
                              (cmacs-brigade-genmail--format-addr
                               (car (plist-get m :from)))))
              (when (plist-get m :message-id)
                (insert (format "   :MSGID: %s\n" (plist-get m :message-id))))
              (insert (format "   :BY: %s\n" (plist-get m :by)))
              (insert "   :END:\n")
              ;; A link back into mu4e, so the report is a place to act
              ;; from rather than a thing to read and then go looking.
              (when (plist-get m :message-id)
                (insert (format "   [[mu4e:msgid:%s][open]]\n"
                                (plist-get m :message-id)))))))))
    file))

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
                    "flag:unread AND NOT maildir:/Spam" 100)))
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
            (format "  %d unread\n" (length unread))
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
