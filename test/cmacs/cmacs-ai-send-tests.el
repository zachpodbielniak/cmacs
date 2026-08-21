;;; cmacs-ai-send-tests.el --- Tests for cmacs-ai-send  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Everything `cmacs-ai-send' decides before it talks to a model is a pure
;; function of the buffer, and that is deliberate: format resolution,
;; instruction bounds, context windowing, history parsing and prompt
;; assembly are the parts that can be wrong in ways you would not notice
;; (a Markdown fence quietly emitted into a .c file, a conversation
;; replayed with two user turns in a row), so they are the parts that are
;; tested here.  No model is called and no build flag is required.
;;
;; markdown-mode does not ship with Emacs, so its resolver is exercised by
;; calling its `:build' through the registry rather than by entering the
;; mode -- which is also a test that the registry is usable from outside.

;;; Code:

(require 'ert)
(require 'cmacs-ai-send)

;;;; Helpers -----------------------------------------------------------

(defmacro cmacs-ai-send-tests--in (mode contents &rest body)
  "Run BODY in a temp buffer in MODE holding CONTENTS.
A `|' in CONTENTS marks where point goes and is removed."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (delay-mode-hooks (funcall ,mode))
     (insert ,contents)
     (goto-char (point-min))
     (if (search-forward "|" nil t)
         (delete-char -1)
       (goto-char (point-max)))
     ,@body))

(defun cmacs-ai-send-tests--build (name)
  "Build the format registered as NAME in the current buffer."
  (funcall (plist-get (gethash name cmacs-ai-send--formats) :build)))

(defun cmacs-ai-send-tests--roundtrip-p (fmt)
  "Non-nil when FMT's regexps match the delimiters FMT writes."
  (let ((begin (format (cmacs-ai-send-format-begin fmt) "claude/opus"))
        (end (cmacs-ai-send-format-end fmt)))
    (and (string-match-p (cmacs-ai-send-format-begin-re fmt) begin)
         (string-match-p (cmacs-ai-send-format-end-re fmt) end)
         ;; The opening regexp must not also match the closing line, or
         ;; history parsing pairs a block with itself.
         (not (string-match-p (cmacs-ai-send-format-begin-re fmt) end)))))

;;;; Format resolution --------------------------------------------------

(ert-deftest cmacs-ai-send-format-org ()
  "An Org buffer resolves to the markup profile, with history on."
  (cmacs-ai-send-tests--in #'org-mode "some prose|\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (eq (cmacs-ai-send-format-kind fmt) 'markup))
      (should (equal (cmacs-ai-send-format-name fmt) "Org"))
      (should (cmacs-ai-send-format-history fmt))
      (should (equal (format (cmacs-ai-send-format-begin fmt) "claude/opus")
                     "#+begin_ai claude/opus"))
      (should (equal (cmacs-ai-send-format-end fmt) "#+end_ai"))
      (should (cmacs-ai-send-tests--roundtrip-p fmt))
      ;; The contract has to forbid the wrong markup by name, since that
      ;; is the failure this whole layer exists to prevent.
      (should (string-match-p "Org" (cmacs-ai-send-format-contract fmt)))
      (should (string-match-p "Markdown"
                              (cmacs-ai-send-format-contract fmt))))))

(ert-deftest cmacs-ai-send-format-markdown ()
  "The Markdown resolver produces HTML-comment delimiters."
  (with-temp-buffer
    (insert "notes\n")
    (let ((fmt (cmacs-ai-send-tests--build 'markdown)))
      (should (eq (cmacs-ai-send-format-kind fmt) 'markup))
      (should (cmacs-ai-send-format-history fmt))
      (should (equal (format (cmacs-ai-send-format-begin fmt) "claude/opus")
                     "<!-- ai: claude/opus -->"))
      (should (equal (cmacs-ai-send-format-end fmt) "<!-- /ai -->"))
      (should (cmacs-ai-send-tests--roundtrip-p fmt)))))

(ert-deftest cmacs-ai-send-format-c ()
  "A C buffer gets block comments -- house style, and free from cc-mode."
  (cmacs-ai-send-tests--in #'c-mode "int main (void) { return 0; }|\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (eq (cmacs-ai-send-format-kind fmt) 'source))
      (should-not (cmacs-ai-send-format-history fmt))
      (should (equal (format (cmacs-ai-send-format-begin fmt) "claude/opus")
                     "/* ai: claude/opus */"))
      (should (equal (cmacs-ai-send-format-end fmt) "/* /ai */"))
      (should (cmacs-ai-send-tests--roundtrip-p fmt))
      ;; A fence in a .c file is a syntax error; the model must be told.
      (should (string-match-p "Markdown"
                              (cmacs-ai-send-format-contract fmt))))))

(ert-deftest cmacs-ai-send-format-python ()
  "A line-comment language gets no trailing delimiter half."
  (cmacs-ai-send-tests--in #'python-mode "x = 1|\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (eq (cmacs-ai-send-format-kind fmt) 'source))
      (should (equal (format (cmacs-ai-send-format-begin fmt) "m")
                     "# ai: m"))
      (should (equal (cmacs-ai-send-format-end fmt) "# /ai"))
      (should (cmacs-ai-send-tests--roundtrip-p fmt)))))

(ert-deftest cmacs-ai-send-format-elisp-doubles-semicolon ()
  "Elisp `comment-start' is \";\"; a standalone comment is \";;\"."
  (cmacs-ai-send-tests--in #'emacs-lisp-mode "(ignore)|\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (equal (format (cmacs-ai-send-format-begin fmt) "m") ";; ai: m"))
      (should (equal (cmacs-ai-send-format-end fmt) ";; /ai"))
      (should (cmacs-ai-send-tests--roundtrip-p fmt)))))

(ert-deftest cmacs-ai-send-format-prose ()
  "A buffer with no comment syntax falls through to plain prose."
  (cmacs-ai-send-tests--in #'text-mode "a letter|\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (eq (cmacs-ai-send-format-kind fmt) 'prose))
      (should (equal (format (cmacs-ai-send-format-begin fmt) "m")
                     "--- ai: m ---"))
      (should (cmacs-ai-send-tests--roundtrip-p fmt)))))

(ert-deftest cmacs-ai-send-format-org-src-block ()
  "Inside `#+begin_src c' the answer must be C, not Org."
  (cmacs-ai-send-tests--in #'org-mode
      "* Notes\n#+begin_src c\nint x = 1;|\n#+end_src\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (eq (cmacs-ai-send-format-kind fmt) 'source))
      (should (equal (cmacs-ai-send-format-end fmt) "/* /ai */"))
      ;; and history is off: code inside a block is not a transcript
      (should-not (cmacs-ai-send-format-history fmt)))))

(ert-deftest cmacs-ai-send-format-tag-is-honoured ()
  "Changing the tag changes both the literals and the regexps together."
  (let ((cmacs-ai-send-tag "llm"))
    (cmacs-ai-send-tests--in #'python-mode "x = 1|\n"
      (let ((fmt (cmacs-ai-send-format-at-point)))
        (should (equal (cmacs-ai-send-format-end fmt) "# /llm"))
        (should (cmacs-ai-send-tests--roundtrip-p fmt))))))

;;;; Heading depth ------------------------------------------------------

(ert-deftest cmacs-ai-send-heading-prefix-org ()
  "When headings are allowed, answers nest under the heading they were
asked in rather than breaking out above it."
  (cmacs-ai-send-tests--in #'org-mode "* Top\n** Sub\nquestion|\n"
    (should (equal (cmacs-ai-send--heading-prefix ?*) "***")))
  (cmacs-ai-send-tests--in #'org-mode "no headings at all|\n"
    (should (equal (cmacs-ai-send--heading-prefix ?*) "*"))))

(ert-deftest cmacs-ai-send-forbids-headings-by-default ()
  "A `* Title' at the top of a reply re-parents every heading below the
insertion point.  Both markup formats must refuse, in the contract and
in the last-position reminder."
  (cmacs-ai-send-tests--in #'org-mode "what is this|\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (string-match-p "Do not use headings"
                              (cmacs-ai-send-format-contract fmt)))
      (should (string-match-p "No headings"
                              (cmacs-ai-send-format-reminder fmt)))
      ;; and it offers the substitute rather than only prohibiting
      (should (string-match-p (regexp-quote "*bolded line*")
                              (cmacs-ai-send-format-reminder fmt)))
      ;; the nesting instruction must be gone, not merely contradicted
      (should-not (string-match-p "one level below"
                                  (cmacs-ai-send-format-contract fmt)))))
  (with-temp-buffer
    (insert "what is this\n")
    (let ((fmt (cmacs-ai-send-tests--build 'markdown)))
      (should (string-match-p "Do not use headings"
                              (cmacs-ai-send-format-contract fmt)))
      (should (string-match-p (regexp-quote "**bolded line**")
                              (cmacs-ai-send-format-reminder fmt))))))

(ert-deftest cmacs-ai-send-org-demands-lowercase-src-language ()
  "Org resolves a babel language by exact string, so `#+BEGIN_SRC C'
neither fontifies nor runs -- and models reach for the capitalised form."
  (cmacs-ai-send-tests--in #'org-mode "q|\n"
    (let ((fmt (cmacs-ai-send-format-at-point)))
      (should (string-match-p "lowercase"
                              (cmacs-ai-send-format-contract fmt)))
      (should (string-match-p "lowercase"
                              (cmacs-ai-send-format-reminder fmt))))))

(ert-deftest cmacs-ai-send-allow-headings-restores-nesting ()
  (let ((cmacs-ai-send-allow-headings t))
    (cmacs-ai-send-tests--in #'org-mode "* Top\nquestion|\n"
      (let ((fmt (cmacs-ai-send-format-at-point)))
        (should (string-match-p "start at [*][*] --"
                                (cmacs-ai-send-format-contract fmt)))
        (should-not (string-match-p "Do not use headings"
                                    (cmacs-ai-send-format-contract fmt)))
        (should-not (string-match-p "No headings"
                                    (cmacs-ai-send-format-reminder fmt)))))))

(ert-deftest cmacs-ai-send-heading-refusal-reaches-the-prompt ()
  "Belt and braces: it must survive into the assembled request, not just
sit in the struct."
  (cmacs-ai-send-tests--in #'org-mode "what is this|\n"
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (prompt (plist-get (cmacs-ai-send--request
                               fmt (point-max) "what is this")
                              :prompt)))
      (should (string-match-p "No headings" prompt))
      (should (string-match-p "Do not use headings"
                              (cmacs-ai-send--system-prompt fmt))))))

(ert-deftest cmacs-ai-send-heading-prefix-markdown ()
  (with-temp-buffer
    (insert "# Top\n## Sub\nquestion\n")
    (should (equal (cmacs-ai-send--heading-prefix ?#) "###"))))

;;;; Instruction bounds -------------------------------------------------

(ert-deftest cmacs-ai-send-instruction-line ()
  (cmacs-ai-send-tests--in #'text-mode "first\nse|cond\nthird\n"
    (let ((bounds (cmacs-ai-send--instruction-bounds)))
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "second")))))

(ert-deftest cmacs-ai-send-instruction-region-wins ()
  (cmacs-ai-send-tests--in #'text-mode "first\nsecond\nthird\n"
    (transient-mark-mode 1)
    (goto-char (point-min))
    (push-mark (point) t t)
    (forward-line 2)
    (let ((bounds (cmacs-ai-send--instruction-bounds)))
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "first\nsecond\n")))))

(ert-deftest cmacs-ai-send-instruction-blank-line-falls-back ()
  "Point on the empty line under a question still sends the question."
  (cmacs-ai-send-tests--in #'text-mode "what is a GIL?\nand why?\n|\nlater\n"
    (let ((bounds (cmacs-ai-send--instruction-bounds)))
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "what is a GIL?\nand why?\n")))))

(ert-deftest cmacs-ai-send-instruction-at-end-of-buffer ()
  "Point at the end of an empty final line -- you typed the question and
pressed RET -- is the single most common position this command is used
from, and `thing-at-point' reports the previous line there."
  (cmacs-ai-send-tests--in #'text-mode "what is a GIL?\n"
    (should (= (point) (point-max)))
    (let ((bounds (cmacs-ai-send--instruction-bounds)))
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "what is a GIL?\n")))))

(ert-deftest cmacs-ai-send-instruction-paragraph-unit ()
  (let ((cmacs-ai-send-instruction-unit 'paragraph))
    (cmacs-ai-send-tests--in #'text-mode "one\ntw|o\n\nnext\n"
      (let ((bounds (cmacs-ai-send--instruction-bounds)))
        (should (equal (buffer-substring-no-properties (car bounds)
                                                       (cdr bounds))
                       "one\ntwo\n"))))))

(ert-deftest cmacs-ai-send-instruction-buffer-to-point ()
  (let ((cmacs-ai-send-instruction-unit 'buffer-to-point))
    (cmacs-ai-send-tests--in #'text-mode "one\ntwo|\nthree\n"
      (let ((bounds (cmacs-ai-send--instruction-bounds)))
        (should (equal (car bounds) (point-min)))
        (should (equal (cdr bounds) (point)))))))

(ert-deftest cmacs-ai-send-insertion-point-is-line-start ()
  "A block never begins halfway along a line."
  (cmacs-ai-send-tests--in #'text-mode "one\ntw|o\nthree\n"
    (let* ((bounds (cmacs-ai-send--instruction-bounds))
           (pos (cmacs-ai-send--insertion-point (cdr bounds))))
      (should (= pos (save-excursion (goto-char pos)
                                     (line-beginning-position))))
      (should (equal (buffer-substring-no-properties pos (point-max))
                     "three\n")))))

;;;; Context ------------------------------------------------------------

(ert-deftest cmacs-ai-send-context-small-buffer-is-verbatim ()
  (cmacs-ai-send-tests--in #'text-mode "alpha\nbeta\ngamma\n"
    (let* ((pos (save-excursion (goto-char (point-min))
                                (line-beginning-position 2)))
           (context (cmacs-ai-send--context pos)))
      (should (equal context
                     (concat "alpha\n" cmacs-ai-send-insertion-marker
                             "beta\ngamma\n"))))))

(ert-deftest cmacs-ai-send-context-windows-around-point ()
  "Over budget, the head survives, the marker survives, and so does the
text either side of it -- which is the part middle-out truncation eats."
  (let ((cmacs-ai-send-context-max-chars 400)
        (cmacs-ai-send-context-head-chars 100))
    (with-temp-buffer
      (insert "HEADER-LINE\n")
      (dotimes (i 400) (insert (format "filler line %03d\n" i)))
      (let* ((pos (progn (goto-char (point-min))
                         (search-forward "filler line 200")
                         (line-beginning-position)))
             (context (cmacs-ai-send--context pos)))
        (should (string-match-p "HEADER-LINE" context))
        (should (string-match-p (regexp-quote cmacs-ai-send-insertion-marker)
                                context))
        (should (string-match-p "filler line 199" context))
        (should (string-match-p "filler line 200" context))
        (should (string-match-p "characters of this file elided" context))
        ;; Budget plus the two elision notes and the marker, not 6400.
        (should (< (length context) 900))))))

(ert-deftest cmacs-ai-send-context-nil-limit-sends-everything ()
  (let ((cmacs-ai-send-context-max-chars nil))
    (with-temp-buffer
      (dotimes (i 200) (insert (format "line %03d\n" i)))
      (let ((context (cmacs-ai-send--context (point-min))))
        (should (string-match-p "line 000" context))
        (should (string-match-p "line 199" context))
        (should-not (string-match-p "elided" context))))))

;;;; History ------------------------------------------------------------

(defconst cmacs-ai-send-tests--transcript
  "#+title: Notes\n\nWhat is a monoid?\n\n#+begin_ai claude/opus\nA set with an associative op and an identity.\n#+end_ai\n\nGive an example.\n\n#+begin_ai claude/opus\nStrings under concatenation.\n#+end_ai\n\nAnd a counterexample?\n"
  "An Org document that has been used as a conversation twice.")

(ert-deftest cmacs-ai-send-history-parses-alternating-turns ()
  (cmacs-ai-send-tests--in #'org-mode cmacs-ai-send-tests--transcript
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (parsed (cmacs-ai-send--history-turns fmt (point-max)))
           (turns (car parsed)))
      (should (equal (mapcar #'car turns) '(user assistant user assistant)))
      (should (string-match-p "monoid" (cdr (nth 0 turns))))
      (should (string-match-p "associative" (cdr (nth 1 turns))))
      (should (equal (cdr (nth 2 turns)) "Give an example."))
      (should (equal (cdr (nth 3 turns)) "Strings under concatenation."))
      ;; The tail is where the turn being sent now begins.
      (should (string-match-p
               "\\`[ \t\n]*And a counterexample\\?"
               (buffer-substring-no-properties (cdr parsed) (point-max)))))))

(ert-deftest cmacs-ai-send-history-drops-trailing-user-turn ()
  "The pending question is appended by the stream, not by the replay --
sending it twice is two user messages in a row, which providers reject."
  (cmacs-ai-send-tests--in #'org-mode cmacs-ai-send-tests--transcript
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (turns (car (cmacs-ai-send--history-turns fmt (point-max)))))
      (should (eq (car (car (last turns))) 'assistant)))))

(ert-deftest cmacs-ai-send-history-stops-at-unterminated-block ()
  (cmacs-ai-send-tests--in #'org-mode
      "Q1\n\n#+begin_ai m\nA1\n#+end_ai\n\nQ2\n\n#+begin_ai m\nstill going\n"
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (turns (car (cmacs-ai-send--history-turns fmt (point-max)))))
      (should (equal (mapcar #'car turns) '(user assistant)))
      (should (equal (cdr (nth 1 turns)) "A1")))))

(ert-deftest cmacs-ai-send-history-respects-max-turns ()
  "Trimming to the most recent N must not leave the list starting on an
assistant turn."
  (let ((cmacs-ai-send-history-max-turns 3))
    (cmacs-ai-send-tests--in #'org-mode cmacs-ai-send-tests--transcript
      (let* ((fmt (cmacs-ai-send-format-at-point))
             (turns (car (cmacs-ai-send--history-turns fmt (point-max)))))
        (should (<= (length turns) 3))
        (should (eq (car (car turns)) 'user))))))

(ert-deftest cmacs-ai-send-history-only-before-the-insertion-point ()
  "A block below where you are asking is not part of the conversation."
  (cmacs-ai-send-tests--in #'org-mode
      "Q1\n\n#+begin_ai m\nA1\n#+end_ai\n\nQ2|\n\n#+begin_ai m\nA2\n#+end_ai\n"
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (turns (car (cmacs-ai-send--history-turns fmt (point)))))
      (should (equal (mapcar #'car turns) '(user assistant)))
      (should (equal (cdr (nth 1 turns)) "A1")))))

(ert-deftest cmacs-ai-send-history-off-in-source-buffers ()
  "Code between two answers is not a transcript."
  (cmacs-ai-send-tests--in #'python-mode
      "# ai: m\nprint(1)\n# /ai\n\nx = 2|\n"
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (bounds (cmacs-ai-send--instruction-bounds))
           (pos (cmacs-ai-send--insertion-point (cdr bounds)))
           (request (cmacs-ai-send--request fmt pos "x = 2")))
      (should-not (plist-get request :history))
      (should (string-match-p (regexp-quote cmacs-ai-send-insertion-marker)
                              (plist-get request :prompt))))))

;;;; Request assembly ---------------------------------------------------

(ert-deftest cmacs-ai-send-request-history-excludes-the-document ()
  "The two context strategies are exclusive: replayed turns already
contain the document, so re-sending it pays for everything twice."
  (cmacs-ai-send-tests--in #'org-mode cmacs-ai-send-tests--transcript
    (goto-char (point-max))
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (request (cmacs-ai-send--request fmt (point)
                                            "And a counterexample?")))
      (should (plist-get request :history))
      (should-not (string-match-p (regexp-quote
                                   cmacs-ai-send-insertion-marker)
                                  (plist-get request :prompt)))
      (should (string-match-p "counterexample" (plist-get request :prompt)))
      ;; ...and the earlier exchange is not smuggled in through the prompt
      (should-not (string-match-p "Strings under concatenation"
                                  (plist-get request :prompt))))))

(ert-deftest cmacs-ai-send-request-first-send-includes-the-document ()
  (cmacs-ai-send-tests--in #'org-mode "* Notes\n\nWhat is a monoid?|\n"
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (request (cmacs-ai-send--request fmt (point-max)
                                            "What is a monoid?")))
      (should-not (plist-get request :history))
      (should (string-match-p (regexp-quote cmacs-ai-send-insertion-marker)
                              (plist-get request :prompt)))
      (should (string-match-p "\\[instruction\\]"
                              (plist-get request :prompt))))))

(ert-deftest cmacs-ai-send-request-context-none ()
  (let ((cmacs-ai-send-context 'none))
    (cmacs-ai-send-tests--in #'c-mode "int x = 1;|\n"
      (let* ((fmt (cmacs-ai-send-format-at-point))
             (request (cmacs-ai-send--request fmt (point-max) "int x = 1;")))
        (should-not (string-match-p (regexp-quote
                                     cmacs-ai-send-insertion-marker)
                                    (plist-get request :prompt)))
        (should (string-match-p "int x = 1;" (plist-get request :prompt)))))))

(ert-deftest cmacs-ai-send-system-prompt-names-the-delimiters ()
  "The model has to be told not to write the delimiters itself, or it
writes a second pair inside the first."
  (cmacs-ai-send-tests--in #'c-mode "int x;|\n"
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (system (cmacs-ai-send--system-prompt fmt)))
      (should (string-match-p (regexp-quote "/* /ai */") system))
      (should (string-match-p (regexp-quote cmacs-ai-send-insertion-marker)
                              system))
      (should (string-match-p "valid c" system)))))

;;;; The format is stated twice, and stated in its own notation --------

(ert-deftest cmacs-ai-send-org-contract-is-written-in-org ()
  "A contract that demonstrates Markdown while forbidding it primes the
model toward exactly what it forbids.  This is a regression test for a
real failure: grok answered an Org buffer in Markdown while being told
in `**bold**' not to."
  (cmacs-ai-send-tests--in #'org-mode "q|\n"
    (let ((contract (cmacs-ai-send-format-contract
                     (cmacs-ai-send-format-at-point))))
      (should-not (string-match-p "\\*\\*" contract))
      (should-not (string-match-p "`" contract))
      ;; and it still says the thing
      (should (string-match-p "never\n?Markdown" contract)))))

(ert-deftest cmacs-ai-send-system-prompt-has-no-markdown-for-org ()
  "The whole system prompt, not only the contract half."
  (cmacs-ai-send-tests--in #'org-mode "q|\n"
    (should-not (string-match-p
                 "\\*\\*" (cmacs-ai-send--system-prompt
                          (cmacs-ai-send-format-at-point))))))

(ert-deftest cmacs-ai-send-every-format-has-a-reminder ()
  (dolist (probe (list (list #'org-mode "q\n")
                       (list #'c-mode "int x;\n")
                       (list #'python-mode "x = 1\n")
                       (list #'text-mode "hello\n")))
    (cmacs-ai-send-tests--in (car probe) (cadr probe)
      (let ((reminder (cmacs-ai-send-format-reminder
                       (cmacs-ai-send-format-at-point))))
        (should (stringp reminder))
        (should-not (string-empty-p reminder)))))
  (with-temp-buffer
    (insert "notes\n")
    (should (stringp (cmacs-ai-send-format-reminder
                      (cmacs-ai-send-tests--build 'markdown))))))

(ert-deftest cmacs-ai-send-reminder-comes-after-the-instruction ()
  "Recency is the whole point: the format must be the last thing read."
  (cmacs-ai-send-tests--in #'org-mode "what is this?|\n"
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (prompt (plist-get (cmacs-ai-send--request
                               fmt (point-max) "what is this?")
                              :prompt)))
      (should (string-match-p "\\[format\\]" prompt))
      (should (< (string-match "\\[instruction\\]" prompt)
                 (string-match "\\[format\\]" prompt)))
      (should (string-suffix-p
               (cmacs-ai-send-format-reminder fmt) (string-trim prompt))))))

(ert-deftest cmacs-ai-send-reminder-survives-the-history-path ()
  "Both request shapes carry it, not just the document one."
  (cmacs-ai-send-tests--in #'org-mode cmacs-ai-send-tests--transcript
    (goto-char (point-max))
    (let* ((fmt (cmacs-ai-send-format-at-point))
           (request (cmacs-ai-send--request fmt (point) "And a counterexample?")))
      (should (plist-get request :history))
      (should (string-match-p "\\[format\\]" (plist-get request :prompt))))))

(ert-deftest cmacs-ai-send-source-reminder-names-the-comment-syntax ()
  (cmacs-ai-send-tests--in #'c-mode "int x;|\n"
    (let ((reminder (cmacs-ai-send-format-reminder
                     (cmacs-ai-send-format-at-point))))
      (should (string-match-p "\\bc\\b" reminder))
      (should (string-match-p (regexp-quote "/* ... */") reminder))))
  (cmacs-ai-send-tests--in #'python-mode "x = 1|\n"
    (let ((reminder (cmacs-ai-send-format-reminder
                     (cmacs-ai-send-format-at-point))))
      (should (string-match-p "python" reminder))
      (should (string-match-p (regexp-quote "#") reminder)))))

;;;; Blocks already in the buffer ---------------------------------------

(ert-deftest cmacs-ai-send-response-at-point-finds-the-block ()
  (cmacs-ai-send-tests--in #'org-mode
      "Q\n\n#+begin_ai m\nA\n#+end_ai\n\nafter|\n"
    (let ((bounds (cmacs-ai-send-response-at-point)))
      (should bounds)
      (should (string-match-p
               "\\`#\\+begin_ai m\nA\n#\\+end_ai\n"
               (buffer-substring-no-properties (car bounds) (cdr bounds)))))))

(ert-deftest cmacs-ai-send-delete-response ()
  (cmacs-ai-send-tests--in #'org-mode
      "Q\n\n#+begin_ai m\nA\n#+end_ai\n|"
    (cmacs-ai-send-delete-response)
    (should (equal (buffer-string) "Q\n\n"))))

(ert-deftest cmacs-ai-send-response-at-point-nil-without-a-block ()
  (cmacs-ai-send-tests--in #'org-mode "just prose|\n"
    (should-not (cmacs-ai-send-response-at-point))))

;;;; Registry -----------------------------------------------------------

(ert-deftest cmacs-ai-send-registry-order-and-override ()
  "A registered format beats the generic derivation, and unregistering
puts it back -- which is what makes this extensible from init.el."
  (unwind-protect
      (progn
        (cmacs-ai-send-register-format
         :name 'cmacs-ai-send-tests--fake
         :modes '(python-mode)
         :order 1
         :build (lambda ()
                  (cmacs-ai-send-format-create
                   :name "Fake" :kind 'prose :lang "fake"
                   :begin "<%s>" :end "</>" :begin-re "^<" :end-re "^</>"
                   :contract "be fake")))
        (cmacs-ai-send-tests--in #'python-mode "x = 1|\n"
          (should (equal (cmacs-ai-send-format-name
                          (cmacs-ai-send-format-at-point))
                         "Fake"))))
    (cmacs-ai-send-unregister-format 'cmacs-ai-send-tests--fake))
  (cmacs-ai-send-tests--in #'python-mode "x = 1|\n"
    (should (eq (cmacs-ai-send-format-kind (cmacs-ai-send-format-at-point))
                'source))))

(ert-deftest cmacs-ai-send-registry-rejects-incomplete ()
  (should-error (cmacs-ai-send-register-format :build #'ignore))
  (should-error (cmacs-ai-send-register-format :name 'x)))

;;;; End to end, with the model stubbed out -------------------------
;;
;; The insertion half is where a mistake is expensive -- it writes into
;; the user's file -- and it needs no provider to exercise: a stub for
;; `cmacs-ai-chat-stream' that calls the callback synchronously drives the
;; whole path, delimiters, undo entry and all.

(defvar cmacs-ai-send-tests--sent nil
  "The (HISTORY . PROMPT) the stub was last called with.")

(defmacro cmacs-ai-send-tests--with-model (payloads &rest body)
  "Run BODY with the AI layer stubbed to emit PAYLOADS, in order."
  (declare (indent 1) (debug t))
  `(let ((cmacs-ai-send-tests--sent nil)
         (history nil))
     (cl-letf (((symbol-function 'cmacs-ai--available-p) (lambda () t))
               ((symbol-function 'cmacs-ai-make-session)
                (lambda (&rest _) (cons 'client 'session)))
               ((symbol-function 'cmacs-ai-free-session) #'ignore)
               ((symbol-function 'cmacs-ai-chat-cancel) #'ignore)
               ((symbol-function 'cmacs-ai-client-provider-name)
                (lambda (&rest _) "claude"))
               ((symbol-function 'cmacs-ai-client-effective-model)
                (lambda (&rest _) "opus"))
               ((symbol-function 'cmacs-ai-session-append-message)
                (lambda (_s role text) (push (cons role text) history)))
               ((symbol-function 'cmacs-ai-chat-stream)
                (lambda (_session prompt callback &optional _executor)
                  (setq cmacs-ai-send-tests--sent
                        (cons (nreverse history) prompt))
                  (dolist (payload ,payloads) (funcall callback payload))
                  t)))
       ,@body)))

(ert-deftest cmacs-ai-send-end-to-end-c ()
  "A send into a C buffer produces a comment-delimited block below the
instruction, and leaves the code above it alone."
  (cmacs-ai-send-tests--with-model
      '((:start) (:delta "int y = 2;") (:end :text "int y = 2;"))
    (cmacs-ai-send-tests--in #'c-mode "int x = 1;|
"
      (cmacs-ai-send)
      (should (equal (buffer-string)
                     (concat "int x = 1;
"
                             "
"
                             "/* ai: claude/opus */
"
                             "int y = 2;
"
                             "/* /ai */
"))))))

(ert-deftest cmacs-ai-send-end-to-end-org-replays-history ()
  "In Org the prior exchange is replayed as turns, and the new block
lands under the question."
  (cmacs-ai-send-tests--with-model
      '((:delta "Not a group: no inverses.")
        (:end :text "Not a group: no inverses."))
    (cmacs-ai-send-tests--in #'org-mode
        "Q1

#+begin_ai claude/opus
A1
#+end_ai

Q2|
"
      (cmacs-ai-send)
      (should (equal (car cmacs-ai-send-tests--sent)
                     '((user . "Q1") (assistant . "A1"))))
      (should (string-match-p "Q2" (cdr cmacs-ai-send-tests--sent)))
      (should (string-match-p
               (concat "Q2

#\\+begin_ai claude/opus
"
                       "Not a group: no inverses.
#\\+end_ai
\\'")
               (buffer-string))))))

(ert-deftest cmacs-ai-send-is-one-undo-step ()
  "Forty deltas, one undo."
  (cmacs-ai-send-tests--with-model
      '((:delta "a") (:delta "b") (:delta "c") (:end :text "abc"))
    (with-temp-buffer
      ;; Undo is disabled in buffers named with a leading space, which is
      ;; exactly what `with-temp-buffer' makes; turn it back on or there
      ;; is nothing to assert about.
      (rename-buffer "cmacs-ai-send-undo-test" t)
      (buffer-enable-undo)
      (delay-mode-hooks (text-mode))
      (insert "question\n")
      (cmacs-ai-send)
      (should (string-match-p "abc" (buffer-string)))
      (undo-boundary)
      (undo)
      (should (equal (buffer-string) "question\n")))))

(ert-deftest cmacs-ai-send-undo-safe-without-undo ()
  "A buffer with undo disabled must not end up with an improper
`buffer-undo-list' -- that breaks undo for everything afterwards."
  (cmacs-ai-send-tests--with-model
      '((:delta "x") (:end :text "x"))
    (cmacs-ai-send-tests--in #'text-mode "question|\n"
      (should (eq buffer-undo-list t))
      (cmacs-ai-send)
      (should (eq buffer-undo-list t)))))

(ert-deftest cmacs-ai-send-empty-answer-leaves-nothing ()
  "An empty reply must not leave an empty block in the file."
  (cmacs-ai-send-tests--with-model '((:end :text ""))
    (cmacs-ai-send-tests--in #'text-mode "question|\n"
      (cmacs-ai-send)
      (should (equal (buffer-string) "question\n")))))

(ert-deftest cmacs-ai-send-error-keeps-what-arrived ()
  "A failure mid-stream closes the block rather than discarding text the
user has already watched appear."
  (cmacs-ai-send-tests--with-model
      '((:delta "partial ans") (:error "connection reset"))
    (cmacs-ai-send-tests--in #'text-mode "question|\n"
      (cmacs-ai-send)
      (should (string-match-p "partial ans" (buffer-string)))
      (should (string-match-p "--- /ai ---" (buffer-string))))))

(ert-deftest cmacs-ai-send-error-with-nothing-leaves-nothing ()
  (cmacs-ai-send-tests--with-model '((:error "no api key"))
    (cmacs-ai-send-tests--in #'text-mode "question|\n"
      (cmacs-ai-send)
      (should (equal (buffer-string) "question\n")))))

(ert-deftest cmacs-ai-send-non-streaming-inserts-at-the-end ()
  "A provider that never emits a delta still gets its answer inserted."
  (let ((cmacs-ai-send-stream nil))
    (cmacs-ai-send-tests--with-model '((:end :text "whole answer"))
      (cmacs-ai-send-tests--in #'text-mode "question|\n"
        (cmacs-ai-send)
        (should (string-match-p "whole answer" (buffer-string)))
        ;; and exactly once -- not once per delivery path
        (should (= 1 (cl-count "whole answer"
                               (split-string (buffer-string) "\n")
                               :test #'string-match-p)))))))

(ert-deftest cmacs-ai-send-refuses-read-only-buffers ()
  (cmacs-ai-send-tests--with-model '((:end :text "hi"))
    (cmacs-ai-send-tests--in #'text-mode "question|\n"
      (setq buffer-read-only t)
      (should-error (cmacs-ai-send) :type 'user-error))))

(ert-deftest cmacs-ai-send-refuses-an-empty-instruction ()
  (cmacs-ai-send-tests--with-model '((:end :text "hi"))
    (with-temp-buffer
      (delay-mode-hooks (text-mode))
      (should-error (cmacs-ai-send) :type 'user-error))))

(ert-deftest cmacs-ai-send-regenerate-replaces-the-block ()
  (cmacs-ai-send-tests--with-model
      '((:delta "second answer") (:end :text "second answer"))
    (cmacs-ai-send-tests--in #'text-mode
        "question\n\n--- ai: claude/opus ---\nfirst answer\n--- /ai ---\n|"
      (cmacs-ai-send-regenerate)
      (should-not (string-match-p "first answer" (buffer-string)))
      (should (string-match-p "second answer" (buffer-string)))
      ;; one block, not two
      (should (= 1 (cl-count "--- /ai ---"
                             (split-string (buffer-string) "\n")
                             :test #'string-match-p))))))

(provide 'cmacs-ai-send-tests)
;;; cmacs-ai-send-tests.el ends here
