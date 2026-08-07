;;; cmacs-brigade-genmail-tests.el --- GenMail tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The parsing and classification are pure functions over data mu hands
;; back, so they are tested without a mail store.  Only the few tests
;; that genuinely need mu skip without it.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-genmail nil 'noerror)

(defun cmacs-brigade-genmail-tests--available-p ()
  (featurep 'cmacs-brigade-genmail))

(defconst cmacs-brigade-genmail-tests--msg
  '(:path "/nonexistent" :subject "Order US123 confirmed"
    :from ((:email "store@ui.com" :name "Ubiquiti Store"))
    :to ((:email "me@example.com"))
    :message-id "abc@example.com")
  "A message in the shape modern mu returns.")

(ert-deftest cmacs-brigade-genmail-address-shapes ()
  "Addresses parse whether mu gave a plist or an old-style cons.

Both appear in the wild depending on which mu indexed the store, and a
mismatch shows up as \"?\" in every report rather than as an error."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (should (equal "a@b.c" (cmacs-brigade-genmail--address '(:email "a@b.c"))))
  (should (equal "a@b.c" (cmacs-brigade-genmail--address '("Name" . "a@b.c"))))
  (should (equal "a@b.c" (cmacs-brigade-genmail--address "a@b.c")))
  (should-not (cmacs-brigade-genmail--address nil))
  (should (equal "N <a@b.c>"
                 (cmacs-brigade-genmail--format-addr '(:email "a@b.c" :name "N"))))
  (should (equal "a@b.c"
                 (cmacs-brigade-genmail--format-addr '(:email "a@b.c"))))
  (should (equal "?" (cmacs-brigade-genmail--format-addr nil))))

(ert-deftest cmacs-brigade-genmail-cheap-rules ()
  "The no-model pass catches what it can identify with certainty.

This is most of the inbox, and every message it classifies is a model
call not made."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  ;; a List-Unsubscribe header is conclusive
  (should (eq 'newsletter
              (cmacs-brigade-genmail--obviously-automated-p
               '(:list "x" :from ((:email "a@b.c")) :subject "hi"))))
  (should (eq 'noise
              (cmacs-brigade-genmail--obviously-automated-p
               '(:from ((:email "no-reply@example.com")) :subject "hi"))))
  (should (eq 'receipt
              (cmacs-brigade-genmail--obviously-automated-p
               cmacs-brigade-genmail-tests--msg)))
  ;; and a real message from a person is left for the model
  (should-not (cmacs-brigade-genmail--obviously-automated-p
               '(:from ((:email "alice@example.com" :name "Alice"))
                 :subject "lunch?"))))

(ert-deftest cmacs-brigade-genmail-bucket-classification ()
  "Recipient class is inferred from the address."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (should (eq 'vendor (cmacs-brigade-genmail--bucket-for "noreply@shop.com")))
  (should (eq 'personal (cmacs-brigade-genmail--bucket-for "alice@gmail.com")))
  (let ((cmacs-brigade-genmail-work-domains '("corp.example")))
    (should (eq 'work (cmacs-brigade-genmail--bucket-for "bob@corp.example")))))

(ert-deftest cmacs-brigade-genmail-strips-others-writing ()
  "Quoted text, signatures and forwarded tails are removed.

The voice profile is about how *you* write; quoted passages are someone
else's writing and would teach the model their voice."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let ((raw "From: x\nSubject: y\n\nMy actual words.\n\n> their quoted words\n> more of theirs\n\n-- \nMy Signature\nPhone\n"))
    (with-temp-buffer
      (insert raw)
      (cmacs-brigade-genmail--strip-headers)
      (cmacs-brigade-genmail--strip-quotes)
      (let ((out (buffer-string)))
        (should (string-search "My actual words" out))
        (should-not (string-search "quoted words" out))
        (should-not (string-search "My Signature" out)))))
  ;; and an "On ... wrote:" tail
  (with-temp-buffer
    (insert "\nMine.\n\nOn Tue, Alice wrote:\nTheirs.\n")
    (cmacs-brigade-genmail--strip-headers)
    (cmacs-brigade-genmail--strip-quotes)
    (should-not (string-search "Theirs" (buffer-string)))))

(ert-deftest cmacs-brigade-genmail-style-features ()
  "Style measurements come out of real bodies."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let ((f (cmacs-brigade-genmail--style-features
            '("Hi there. Short one. Thanks"
              "Hello. This one is a good deal longer and has more words in it."))))
    (should (= 2 (plist-get f :samples)))
    (should (> (plist-get f :mean-words) 0))
    ;; both open with a greeting
    (should (> (plist-get f :greeting-rate) 0.9))))

(ert-deftest cmacs-brigade-genmail-exemplars-span-lengths ()
  "Exemplars are chosen across the length range, not the first N.

A dozen examples of the same three-line reply teaches nothing about how
someone writes a considered one."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let* ((bodies (mapcar (lambda (n) (make-string n ?x)) (number-sequence 1 100)))
         (picked (cmacs-brigade-genmail--pick-exemplars bodies 5)))
    (should (= 5 (length picked)))
    (should (< (length (car picked)) (length (car (last picked)))))))

(ert-deftest cmacs-brigade-genmail-tools-registered ()
  "The mail tools reach the agent surfaces like anything else."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (should (cmacs-brigade-registry-get 'tool 'mail-search))
  (should (cmacs-brigade-registry-get 'tool 'mail-read))
  ;; read-only: neither may write, send or delete
  (should-not (cmacs-brigade-tool-destructive
               (cmacs-brigade-registry-get 'tool 'mail-search))))

(ert-deftest cmacs-brigade-genmail-flags-off-by-default ()
  "Triage does not touch real mail until told it may."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (should-not (default-value 'cmacs-brigade-genmail-apply-flags)))

(ert-deftest cmacs-brigade-genmail-triage-writes-org ()
  "A triage report is org, with a link back into mu4e for each message."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let* ((dir (make-temp-file "genmail-test" t))
         (cmacs-brigade-genmail-output-directory dir))
    (unwind-protect
        (let ((file (cmacs-brigade-genmail--write-triage
                     (list (append cmacs-brigade-genmail-tests--msg
                                   (list :bucket 'receipt :by 'rule))))))
          (should (file-exists-p file))
          (with-temp-buffer
            (insert-file-contents file)
            (let ((s (buffer-string)))
              (should (string-search "* receipt (1)" s))
              (should (string-search "Order US123 confirmed" s))
              ;; the report is a place to act from, not just to read
              (should (string-search "[[mu4e:msgid:abc@example.com]" s))
              (should (string-search ":BY: rule" s)))))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-genmail-unread-query-is-inbox-only ()
  "Triage reads the inbox, not every unread message in the store.

Mail that has been filed is unread on purpose; triaging the archive
every morning buries what actually arrived."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  ;; the derivation picks inboxes out of a store, at any depth, and
  ;; leaves everything else alone
  (let ((cmacs-brigade-genmail--maildirs
         '("/Archive" "/INBOX" "/Sent" "/Spam" "/work/Inbox" "/Folders/Notes"))
        (cmacs-brigade-genmail-inbox-query nil))
    (should (equal '("/INBOX" "/work/Inbox")
                   (cmacs-brigade-genmail--inbox-maildirs)))
    (let ((q (cmacs-brigade-genmail--unread-query)))
      (should (string-search "flag:unread" q))
      (should (string-search "maildir:\"/INBOX\"" q))
      (should (string-search "maildir:\"/work/Inbox\"" q))
      (should-not (string-search "/Archive" q))))
  ;; an unrecognisable store falls back to the conventional name, never
  ;; to the whole store
  (let ((cmacs-brigade-genmail--maildirs 'none)
        (cmacs-brigade-genmail-inbox-query nil))
    (should (equal "maildir:/INBOX" (cmacs-brigade-genmail--inbox-query))))
  ;; and an explicit query wins outright
  (let ((cmacs-brigade-genmail-inbox-query "maildir:/mine"))
    (should (string-search "maildir:/mine"
                           (cmacs-brigade-genmail--unread-query)))))

(ert-deftest cmacs-brigade-genmail-parses-the-format-it-asked-for ()
  "The numbered answer the prompt requests parses exactly."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (should (equal [act-now reply noise]
                 (cmacs-brigade-genmail--parse-buckets
                  "1 act-now\n2. reply\n3) noise\n" 3)))
  ;; a bucket that is not one of ours is refused, not interned and used
  (should (equal [reply nil]
                 (cmacs-brigade-genmail--parse-buckets
                  "1. reply\n2. urgent-ish\n" 2))))

(ert-deftest cmacs-brigade-genmail-parses-a-model-that-wrote-prose ()
  "A chatty answer still yields buckets.

A small local model told to answer \"NUMBER BUCKET\" will sometimes
write a section per message instead, and throwing that away would mean
falling back to `reply' for mail the model actually classified."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let ((prose (concat
                "Sure! Here is my classification:\n\n"
                "### 1. Message One\n"
                "This one is bulk marketing, so newsletter fits best.\n\n"
                "### 2. Message Two\n"
                "Production is down, so this is act-now.\n")))
    (should (equal [newsletter act-now]
                   (cmacs-brigade-genmail--parse-buckets prose 2))))
  ;; and an answer with no bucket word anywhere leaves the slots nil,
  ;; which the caller records as unclassified rather than as a guess
  (should (equal [nil nil]
                 (cmacs-brigade-genmail--parse-buckets
                  "1. Priority: Medium\n2. Priority: Critical\n" 2))))

(ert-deftest cmacs-brigade-genmail-unanswered-is-marked-not-guessed ()
  "A message the model did not classify says so in the report.

Filing it under `reply' is the safe default, but recording it as though
a model had decided would make the report claim more than it knows."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let* ((m1 (list :subject "a" :bucket 'reply :by 'pending))
         (m2 (list :subject "b" :bucket 'reply :by 'pending))
         (pending (list m1 m2)))
    (cmacs-brigade-genmail--apply-buckets pending "1 act-now\n")
    (should (eq 'act-now (plist-get m1 :bucket)))
    (should (eq 'model   (plist-get m1 :by)))
    (should (eq 'reply        (plist-get m2 :bucket)))
    (should (eq 'unclassified (plist-get m2 :by)))))

(ert-deftest cmacs-brigade-genmail-rules-only-without-a-model ()
  "With the model pass off, triage still produces a report.

The rules are the floor, not an optimisation: a build with no cmacs-ai,
an ollama that is not running, or `use-model' nil must all still sort
the mail they can and write it out."
  (skip-unless (and (cmacs-brigade-genmail-tests--available-p)
                    (cmacs-brigade-genmail-available-p)))
  (let* ((dir (make-temp-file "genmail-rules" t))
         (cmacs-brigade-genmail-output-directory dir)
         (cmacs-brigade-genmail-use-model nil))
    (unwind-protect
        (let ((file (cmacs-brigade-genmail-triage 5)))
          (should (file-exists-p file))
          (should (equal file (cmacs-brigade-genmail--triage-file))))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-genmail-writes-what-the-rules-know-first ()
  "Messages awaiting the model are written as pending, not as decided.

The report is opened before the model answers, so what it says in the
meantime has to be true: `pending' is its own section, and the header
says what is still outstanding."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let* ((dir (make-temp-file "genmail-interim" t))
         (cmacs-brigade-genmail-output-directory dir)
         (waiting (list :subject "a real person wrote this"
                        :from '((:email "alice@example.com"))
                        :message-id "p@x" :bucket 'pending :by 'pending))
         (ruled (list :subject "Weekly digest"
                      :from '((:email "news@mail.example"))
                      :message-id "r@x" :bucket 'newsletter :by 'rule)))
    (unwind-protect
        (progn
          (cmacs-brigade-genmail--write-triage (list ruled waiting))
          (with-temp-buffer
            (insert-file-contents (cmacs-brigade-genmail--triage-file))
            (let ((s (buffer-string)))
              (should (string-search "* pending (1)" s))
              (should (string-search "* newsletter (1)" s))
              (should (string-match-p "Waiting on .* for 1 message" s))))
          ;; and once it settles, nothing claims to be pending any more
          (cmacs-brigade-genmail--settle-pending (list waiting))
          (should (eq 'reply (plist-get waiting :bucket)))
          (should (eq 'unclassified (plist-get waiting :by)))
          (cmacs-brigade-genmail--write-triage (list ruled waiting))
          (with-temp-buffer
            (insert-file-contents (cmacs-brigade-genmail--triage-file))
            (let ((s (buffer-string)))
              (should-not (string-search "* pending" s))
              (should-not (string-search "Waiting on" s)))))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-genmail-updates-the-open-report-in-place ()
  "The model's answer refreshes the report you are already reading.

Point is kept, because an answer landing mid-read must not throw away
where you were; and a buffer with your own edits in it is never
clobbered."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let* ((dir (make-temp-file "genmail-refresh" t))
         (cmacs-brigade-genmail-output-directory dir)
         (waiting (list :subject "a real person wrote this"
                        :from '((:email "alice@example.com"))
                        :message-id "p@x" :bucket 'pending :by 'pending))
         (file (cmacs-brigade-genmail--write-triage (list waiting)))
         (buf (find-file-noselect file)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (should (string-search "* pending" (buffer-string)))
            (goto-char (point-min))
            (forward-line 2))
          ;; the model answers
          (cmacs-brigade-genmail--apply-buckets (list waiting) "1 act-now\n")
          (let ((pos (with-current-buffer buf (point))))
            (cmacs-brigade-genmail--triage-finish (list waiting) nil)
            (with-current-buffer buf
              (should (string-search "* act-now" (buffer-string)))
              (should-not (string-search "* pending" (buffer-string)))
              (should (= pos (point)))))
          ;; a buffer with edits is left alone
          (with-current-buffer buf (goto-char (point-max)) (insert "my note\n"))
          (plist-put waiting :bucket 'noise)
          (cmacs-brigade-genmail--triage-finish (list waiting) nil)
          (with-current-buffer buf
            (should (string-search "my note" (buffer-string)))
            (should (buffer-modified-p))))
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf)
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-genmail-pending-is-not-a-model-answer ()
  "`pending' is a report section, never something a model may return.

It reads like a bucket, and a model allowed to answer with it could
leave a message permanently waiting on an answer that already came."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (should-not (memq 'pending cmacs-brigade-genmail-buckets))
  (should (equal [nil] (cmacs-brigade-genmail--parse-buckets "1 pending\n" 1))))

(ert-deftest cmacs-brigade-genmail-takes-a-cli-ollama-model ()
  "A `claude-code/ollama/NAME' triage model splits the way ai-glib needs.

The provider is the first component only; everything after it is the
model string that provider receives, so the `ollama/' prefix the CLI
clients look for has to survive the split intact."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (should (equal '(claude-code . "ollama/qwen3.5:9b")
                 (cmacs-brigade-genmail--split-model
                  "claude-code/ollama/qwen3.5:9b")))
  (should (equal '(claude-tmux . "ollama/gemma4:12b")
                 (cmacs-brigade-genmail--split-model
                  "claude-tmux/ollama/gemma4:12b")))
  ;; and the plain provider forms are unaffected
  (should (equal '(ollama . "qwen3.5:9b")
                 (cmacs-brigade-genmail--split-model "ollama/qwen3.5:9b")))
  (should (equal '(claude . "claude-sonnet-4-6")
                 (cmacs-brigade-genmail--split-model
                  "claude/claude-sonnet-4-6"))))

(ert-deftest cmacs-brigade-genmail-report-links-are-followable ()
  "Something answers a `mu4e:' link, with or without mu4e.

An unregistered link type is not an error in org -- it falls through to
a heading search, so the report's links ask \"create this as a new
heading?\" instead of opening the mail, which is the one thing the
report exists to make easy."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (require 'org)
  (cmacs-brigade-genmail-ensure-link-type)
  (should (org-link-get-parameter "mu4e" :follow))
  ;; and a link shape we do not write is refused rather than mishandled
  (should-error (cmacs-brigade-genmail--follow-link "query:flag:unread")))

(ert-deftest cmacs-brigade-genmail-renders-a-message-readably ()
  "A message renders as headers plus text, not as MIME.

The point of following a link is to decide what to do with the message,
which cannot be done while reading base64."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let ((raw (concat "From: Alice <alice@example.com>\n"
                     "To: me@example.com\n"
                     "Subject: =?utf-8?q?caf=C3=A9_meeting?=\n"
                     "Content-Type: text/plain; charset=utf-8\n"
                     "\n"
                     "Body text here.\n")))
    (with-temp-buffer
      (insert raw)
      (cmacs-brigade-genmail--render-message)
      (let ((out (buffer-string)))
        ;; the encoded-word subject is decoded, not shown as =?utf-8?q?
        (should (string-search "café meeting" out))
        (should-not (string-search "=?utf-8?" out))
        (should (string-search "alice@example.com" out))
        (should (string-search "Body text here." out))
        ;; headers that are noise for a decision are left out
        (should-not (string-search "Content-Type" out))))))

(ert-deftest cmacs-brigade-genmail-flattens-multipart ()
  "Multipart messages yield their leaf parts.

`mm-dissect-buffer' answers a single handle for a simple message and a
tree otherwise; walking only one shape renders an alternative-part
newsletter as nothing at all."
  (skip-unless (cmacs-brigade-genmail-tests--available-p))
  (let* ((leaf-a (list (generate-new-buffer " *a*") '("text/plain")))
         (leaf-b (list (generate-new-buffer " *b*") '("text/html")))
         (tree (list "multipart/alternative" leaf-a leaf-b)))
    (unwind-protect
        (progn
          (should (equal (list leaf-a)
                         (cmacs-brigade-genmail--flatten-handles leaf-a)))
          (should (equal (list leaf-a leaf-b)
                         (cmacs-brigade-genmail--flatten-handles tree))))
      (kill-buffer (car leaf-a))
      (kill-buffer (car leaf-b)))))

(ert-deftest cmacs-brigade-genmail-no-matches-is-not-an-error ()
  "A query matching nothing returns nil rather than signalling.

mu exits 2 for \"no matches\", which is an answer -- an empty inbox is a
normal Tuesday."
  (skip-unless (and (cmacs-brigade-genmail-tests--available-p)
                    (cmacs-brigade-genmail-available-p)))
  (should-not (cmacs-brigade-genmail-query
               "subject:zzz-definitely-no-such-message-zzz" 1)))

(provide 'cmacs-brigade-genmail-tests)

;;; cmacs-brigade-genmail-tests.el ends here
