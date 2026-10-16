;;; cmacs-gowl-bar-rewrite-tests.el --- Tests for the ai-rewrite bar actions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The cmacs half of gowl's `ai-rewrite' widget: the action list cmacs
;; pushes, and the line format it travels in.  gowl's
;; tests/test-bar-ai-rewrite.c parses the SAME golden string
;; (tests/fixtures/bar/ai-rewrite/pushed-from-cmacs.txt there), so a
;; change to the format on either side fails one of the two suites.
;;
;; No bar: `cmacs-gowl-bar-push-function' is rebound to record pushes.
;;
;; What these catch:
;;
;;   - a prompt with a tab, newline, backslash or quote splitting or
;;     corrupting its record (the widget would drop it, or worse, run a
;;     different prompt);
;;   - the default list losing proofread as its first action, or losing
;;     any text operation the right-click menu offers;
;;   - a customised system prompt or refinement NOT reaching the bar
;;     (the list must be built at push time, not copied);
;;   - the push forgetting `ai-backend=cmacs' or the bottom bar, or
;;     signalling when the bar is not there.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'cmacs-gowl-bar-ai)
(require 'cmacs-gowl-bar-rewrite)
;; Loaded now, not by the code under test: a `require' inside a test
;; would redefine what the test has stubbed.
(require 'cmacs-ai nil t)
(require 'cmacs-ai-textops nil t)
(require 'cmacs-ai-proofread nil t)

(defconst cmacs-gowl-bar-rewrite-tests--golden
  (concat "#ai-rewrite-actions 1\n"
          "t\ttone\tTone \"down\"\tp\tHow?\t\t\t"
          "Line 1\\nLine\\t2 \\\\ back\t"
          "Rewrite: {input}\\n\\n“日本語”\n")
  "One hostile action, serialised.  Byte-identical to gowl's
tests/fixtures/bar/ai-rewrite/pushed-from-cmacs.txt.")

(defconst cmacs-gowl-bar-rewrite-tests--golden-action
  (list :key "t" :id "tone" :label "Tone \"down\""
        :system "Line 1\nLine\t2 \\ back"
        :instruction "Rewrite: {input}\n\n“日本語”"
        :input "How?" :provider nil :model nil :preview t :diff nil))

(ert-deftest cmacs-gowl-bar-rewrite-test-golden-format ()
  "The serialiser writes exactly what gowl's parser is tested against."
  (should (equal (cmacs-gowl-bar-rewrite-serialize
                  (list cmacs-gowl-bar-rewrite-tests--golden-action))
                 cmacs-gowl-bar-rewrite-tests--golden)))

(ert-deftest cmacs-gowl-bar-rewrite-test-escape-round-trip ()
  "Every hostile field survives escape then unescape, and never leaves a
raw tab or newline behind to split the record."
  (dolist (text '("" "plain" "tab\there" "new\nline\r\nCRLF"
                  "back\\slash \\t literal \\n not escapes"
                  "trailing backslash \\"
                  "\"quotes\" 'single' `backtick' (parens)"
                  "Naïve café — “smart” 日本語 \U0001F44D"
                  "\t\n\\\t\n\\"))
    (let ((esc (cmacs-gowl-bar-rewrite--escape text)))
      (should-not (string-match-p "[\t\n\r]" esc))
      (should (equal (cmacs-gowl-bar-rewrite--unescape esc) text))))
  (should (equal (cmacs-gowl-bar-rewrite--escape nil) "")))

(ert-deftest cmacs-gowl-bar-rewrite-test-serialised-records ()
  "One header plus one nine-field line per action, whatever the prompts."
  (let* ((actions (list cmacs-gowl-bar-rewrite-tests--golden-action
                        (list :key nil :id "x" :label "X\tY"
                              :system nil :instruction "a\nb"
                              :preview nil :diff t)))
         (lines (split-string (cmacs-gowl-bar-rewrite-serialize actions)
                              "\n" t)))
    (should (equal (car lines) "#ai-rewrite-actions 1"))
    (should (= (length lines) 3))
    (dolist (line (cdr lines))
      (should (= (length (split-string line "\t")) 9)))
    ;; Flags: preview off, diff on; no key.
    (should (string-prefix-p "\tx\tX\\tY\td\t" (nth 2 lines)))))

(ert-deftest cmacs-gowl-bar-rewrite-test-default-list ()
  "Proofread first, every textual text operation offered, keys unique."
  (skip-unless (boundp 'cmacs-ai-textops--specs))
  (let* ((resolved (cmacs-gowl-bar-rewrite-resolve))
         (ids (mapcar (lambda (a) (plist-get a :id)) resolved))
         (keys (delq nil (mapcar (lambda (a) (plist-get a :key)) resolved)))
         (ops (delq nil
                    (mapcar (lambda (entry)
                              (pcase (nth 4 entry)
                                (`(textops ,op . ,_) op)))
                            cmacs-gowl-bar-rewrite-actions))))
    (should (equal (car ids) "proofread"))
    (should (equal (plist-get (car resolved) :key) "f"))
    ;; Every operation the right-click AI menu runs on text.
    (dolist (op (mapcar #'car cmacs-ai-textops--specs))
      (should (memq op ops)))
    (dolist (id '("improve" "shorten" "translate-en" "custom"))
      (should (member id ids)))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))
    ;; The panel's own keys are not used.
    (dolist (k '("j" "k" "y" "v"))
      (should-not (member k keys)))
    ;; Every action resolved to a real instruction.
    (dolist (a resolved)
      (should (stringp (plist-get a :instruction)))
      (should (> (length (plist-get a :instruction)) 0)))
    ;; Ask and Custom ask for a line and put it in the prompt.
    (dolist (id '("ask" "custom"))
      (let ((a (seq-find (lambda (a) (equal (plist-get a :id) id))
                         resolved)))
        (should (plist-get a :input))
        (should (string-match-p "{input}" (plist-get a :instruction)))))
    ;; Answers that are not rewrites are shown as text, not as diffs.
    (dolist (id '("summarize" "explain" "reply" "ask"))
      (should-not (plist-get (seq-find (lambda (a)
                                         (equal (plist-get a :id) id))
                                       resolved)
                             :diff)))))

(ert-deftest cmacs-gowl-bar-rewrite-test-proofread-prompt ()
  "Proofread carries the menu's own system prompt and instruction."
  (skip-unless (and (boundp 'cmacs-ai-textops--specs)
                    (boundp 'cmacs-ai-proofread-system-prompt)))
  (let ((a (car (cmacs-gowl-bar-rewrite-resolve)))
        (spec (alist-get 'proofread cmacs-ai-textops--specs)))
    (should (equal (plist-get a :system) cmacs-ai-proofread-system-prompt))
    (should (equal (plist-get a :instruction)
                   (format "%s\n\nHow: %s\n\nThe text:"
                           (plist-get spec :instruction)
                           (plist-get spec :default))))))

(ert-deftest cmacs-gowl-bar-rewrite-test-customisation-honoured ()
  "A customised system prompt and refinement reach the pushed list."
  (skip-unless (and (boundp 'cmacs-ai-textops--specs)
                    (boundp 'cmacs-ai-rephrase-system-prompt)))
  (let* ((cmacs-ai-rephrase-system-prompt "CUSTOM REPHRASE SYSTEM")
         (cmacs-ai-textops--specs
          (cons (list 'rephrase :instruction "Say it again."
                      :default "in pirate speak")
                (assq-delete-all 'rephrase
                                 (copy-sequence cmacs-ai-textops--specs))))
         (resolved (cmacs-gowl-bar-rewrite-resolve))
         (rephrase (seq-find (lambda (a) (equal (plist-get a :id) "rephrase"))
                             resolved))
         (custom (seq-find (lambda (a) (equal (plist-get a :id) "custom"))
                           resolved)))
    (should (equal (plist-get rephrase :system) "CUSTOM REPHRASE SYSTEM"))
    (should (equal (plist-get rephrase :instruction)
                   "Say it again.\n\nHow: in pirate speak\n\nThe text:"))
    (should (equal (plist-get custom :instruction)
                   "Say it again.\n\nHow: {input}\n\nThe text:"))
    (should (string-match-p "CUSTOM REPHRASE SYSTEM"
                            (cmacs-gowl-bar-rewrite-serialize resolved)))))

(ert-deftest cmacs-gowl-bar-rewrite-test-unresolvable-skipped ()
  "An action naming a text operation that does not exist is left out."
  (let ((cmacs-gowl-bar-rewrite-actions
         '(("q" "gone" "Gone" nil (textops no-such-op))
           ("w" "kept" "Kept" "sys" "Do it."))))
    (should (equal (mapcar (lambda (a) (plist-get a :id))
                           (cmacs-gowl-bar-rewrite-resolve))
                   '("kept")))))

(ert-deftest cmacs-gowl-bar-rewrite-test-push ()
  "The push names the widget in both bars, selects the cmacs backend,
carries the list and the providers, and returns nil."
  (let ((pushes nil))
    (cl-letf (((symbol-function 'cmacs-gowl-bar-ai-provider-names)
               (lambda (&rest _) '("claude" "ollama"))))
      (let ((cmacs-gowl-bar-push-function
             (lambda (alist) (push alist pushes))))
        (should-not (cmacs-gowl-bar-rewrite-push))))
    (let ((all (apply #'append pushes)))
      (should (equal (cdr (assoc "ai-rewrite.ai-backend" all)) "cmacs"))
      (should (equal (cdr (assoc "bottom-ai-rewrite.ai-backend" all))
                     "cmacs"))
      (should (equal (cdr (assoc "ai-rewrite.actions-mode" all)) "replace"))
      (should (equal (cdr (assoc "ai-rewrite.ai-providers" all))
                     "claude,ollama"))
      (let ((spec (cdr (assoc "ai-rewrite.actions" all))))
        (should (string-prefix-p "#ai-rewrite-actions 1\n" spec))
        (should (equal spec (cdr (assoc "bottom-ai-rewrite.actions" all))))
        (should (= (length (split-string spec "\n" t))
                   (1+ (length (cmacs-gowl-bar-rewrite-resolve)))))))))

(ert-deftest cmacs-gowl-bar-rewrite-test-push-never-signals ()
  "A bar that is not there is not an error for the code pushing to it."
  (let ((cmacs-gowl-bar-push-function
         (lambda (&rest _) (error "No bar running"))))
    (cl-letf (((symbol-function 'cmacs-gowl-bar-ai-provider-names)
               (lambda (&rest _) (error "No cmacs-ai"))))
      (should-not (cmacs-gowl-bar-rewrite-push)))))

(provide 'cmacs-gowl-bar-rewrite-tests)

;;; cmacs-gowl-bar-rewrite-tests.el ends here
