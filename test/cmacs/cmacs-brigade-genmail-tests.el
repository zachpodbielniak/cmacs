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
