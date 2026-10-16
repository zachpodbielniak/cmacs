;;; cmacs-gowl-bar-ai-tests.el --- Tests for the gowl bar AI contract  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The cmacs half of gowl's bar-ai contract: `cmacs-gowl-bar-ai-run'
;; returns at once and streams the answer back as WIDGET.ai-* settings.
;; gowl's tests/test-bar-ai.c holds the other half (the widget side) to
;; the same names, so a rename on either side fails one of the two.
;;
;; No bar and no model: `cmacs-gowl-bar-push-function' is rebound to
;; record what would have been pushed, and the cmacs-ai entry points are
;; stubbed with &rest (the ERT stub arity trap).
;;
;; What these catch:
;;
;;   - a push that reaches only the top bar (a widget in the bottom bar
;;     would wait forever);
;;   - the run blocking until the model answers (under --gowl that is a
;;     frozen desktop) -- asserted by the run returning before any
;;     answer exists;
;;   - an error signalled out of the run instead of pushed as state;
;;   - a model default being borrowed for a provider it means nothing to.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-bar-ai)
;; Loaded now, not by the code under test: a `require' that loads
;; cmacs-ai.el inside a test would redefine the functions the test has
;; just stubbed.
(require 'cmacs-ai nil t)
(require 'cmacs-ai-textops nil t)

(defmacro cmacs-gowl-bar-ai-tests--with (pushes calls &rest body)
  "Run BODY recording PUSHES (alists, oldest first) and stream CALLS.
Each call is (CALLBACK PROMPT PROVIDER MODEL SYSTEM)."
  (declare (indent 2))
  `(let ((,pushes nil)
         (,calls nil)
         (session-args nil)
         (cmacs-gowl-bar-ai-push-interval 0))
     (cl-letf* ((cmacs-gowl-bar-push-function
                 (lambda (alist) (setq ,pushes (append ,pushes (list alist)))))
                ((symbol-function 'cmacs-ai--ensure) (lambda (&rest _) t))
                ((symbol-function 'cmacs-ai-free-session) (lambda (&rest _) nil))
                ((symbol-function 'cmacs-ai-make-session)
                 (lambda (&rest args) (setq session-args args)
                   (cons 'client 'session)))
                ((symbol-function 'cmacs-ai-chat-stream)
                 (lambda (&rest args)
                   (setq ,calls
                         (append ,calls
                                 (list (list (nth 2 args) (nth 1 args)
                                             (nth 0 session-args)
                                             (nth 1 session-args)
                                             (nth 2 session-args)))))
                   nil)))
       ,@body)))

(defun cmacs-gowl-bar-ai-tests--get (alist key)
  "The value of KEY in a pushed ALIST."
  (cdr (assoc key alist)))

(ert-deftest cmacs-gowl-bar-ai-test-push-reaches-both-bars ()
  "Every setting goes out as WIDGET.KEY and bottom-WIDGET.KEY."
  (let (seen)
    (let ((cmacs-gowl-bar-push-function (lambda (a) (setq seen a))))
      (cmacs-gowl-bar-push "ai-rewrite" '(("ai-state" . "done")
                                          ("ai-text" . nil))))
    (should (equal seen '(("ai-rewrite.ai-state" . "done")
                          ("bottom-ai-rewrite.ai-state" . "done")
                          ("ai-rewrite.ai-text" . "")
                          ("bottom-ai-rewrite.ai-text" . ""))))))

(ert-deftest cmacs-gowl-bar-ai-test-push-never-signals ()
  "A bar that is not there is not an error for the code pushing to it."
  (let ((cmacs-gowl-bar-push-function
         (lambda (_) (error "no compositor"))))
    (should-not (cmacs-gowl-bar-push "w" '(("k" . "v"))))))

(ert-deftest cmacs-gowl-bar-ai-test-run-returns-before-the-answer ()
  "The run answers t at once; the model's text arrives later, pushed."
  (cmacs-gowl-bar-ai-tests--with pushes calls
    (should (eq t (cmacs-gowl-bar-ai-run "ai-rewrite" "req-1" "Fix."
                                         "teh cat" "ollama" "qwen3")))
    ;; Started, but nothing answered yet: only the waiting push.
    (should (= 1 (length calls)))
    (should (= 1 (length pushes)))
    (should (equal (cmacs-gowl-bar-ai-tests--get (car pushes)
                                                 "ai-rewrite.ai-state")
                   "waiting"))
    (should (equal (cmacs-gowl-bar-ai-tests--get (car pushes)
                                                 "ai-rewrite.ai-id")
                   "req-1"))
    ;; The session was made for the named provider, model and system.
    (should (equal (nth 1 (car calls)) "teh cat"))
    (should (eq (nth 2 (car calls)) 'ollama))
    (should (equal (nth 3 (car calls)) "qwen3"))
    (should (equal (nth 4 (car calls)) "Fix."))
    ;; Stream it.
    (let ((cb (car (car calls))))
      (funcall cb '(:delta "the "))
      (funcall cb '(:delta "cat\n"))
      (funcall cb '(:end)))
    (let ((last (car (last pushes))))
      (should (equal (cmacs-gowl-bar-ai-tests--get last "ai-rewrite.ai-state")
                     "done"))
      ;; Trailing whitespace trimmed; bottom bar told too.
      (should (equal (cmacs-gowl-bar-ai-tests--get last "ai-rewrite.ai-text")
                     "the cat"))
      (should (equal (cmacs-gowl-bar-ai-tests--get
                      last "bottom-ai-rewrite.ai-text")
                     "the cat")))
    ;; Something streamed in between.
    (should (cl-some (lambda (a)
                       (equal (cmacs-gowl-bar-ai-tests--get
                               a "ai-rewrite.ai-state")
                              "streaming"))
                     pushes))))

(ert-deftest cmacs-gowl-bar-ai-test-throttles-pushes ()
  "Many deltas inside the interval make one pending push, not many."
  (cmacs-gowl-bar-ai-tests--with pushes calls
    (let ((cmacs-gowl-bar-ai-push-interval 60))
      (cmacs-gowl-bar-ai-run "w" "id" nil "p")
      (let ((cb (car (car calls))))
        (dotimes (_ 50) (funcall cb '(:delta "x")))
        ;; waiting + at most one immediate streaming push.
        (should (<= (length pushes) 2))
        (funcall cb '(:end))))
    (should (equal (cmacs-gowl-bar-ai-tests--get (car (last pushes)) "w.ai-text")
                   (make-string 50 ?x)))))

(ert-deftest cmacs-gowl-bar-ai-test-errors-are-pushed-not-signalled ()
  "A failure to start and a stream error both become ai-state error."
  (cmacs-gowl-bar-ai-tests--with pushes calls
    (cl-letf (((symbol-function 'cmacs-ai-make-session)
               (lambda (&rest _) (error "no API key"))))
      (should (eq t (cmacs-gowl-bar-ai-run "w" "id" nil "p"))))
    (let ((last (car (last pushes))))
      (should (equal (cmacs-gowl-bar-ai-tests--get last "w.ai-state") "error"))
      (should (string-match-p "no API key"
                              (cmacs-gowl-bar-ai-tests--get last
                                                            "w.ai-error")))))
  (cmacs-gowl-bar-ai-tests--with pushes calls
    (cmacs-gowl-bar-ai-run "w" "id" nil "p")
    (funcall (car (car calls)) '(:error "rate limited"))
    (should (equal (cmacs-gowl-bar-ai-tests--get (car (last pushes)) "w.ai-error")
                   "rate limited"))
    ;; Nothing after the end is pushed again.
    (let ((n (length pushes)))
      (funcall (car (car calls)) '(:end))
      (should (= n (length pushes))))))

(ert-deftest cmacs-gowl-bar-ai-test-bad-arguments-signal ()
  "Non-string arguments are a programming error, said loudly."
  (should-error (cmacs-gowl-bar-ai-run 'w "id" nil "p"))
  (should-error (cmacs-gowl-bar-ai-run "w" nil nil "p")))

(ert-deftest cmacs-gowl-bar-ai-test-provider-and-model-defaults ()
  "A model default is borrowed only along with its provider."
  (let ((cmacs-ai-textops-provider 'claude-code)
        (cmacs-ai-textops-model "sonnet")
        (cmacs-gowl-bar-ai-provider nil)
        (cmacs-gowl-bar-ai-model nil))
    ;; Nothing named: the AI menu's provider AND model.
    (should (eq (cmacs-gowl-bar-ai--provider nil) 'claude-code))
    (should (equal (cmacs-gowl-bar-ai--model nil nil) "sonnet"))
    ;; A provider named by the widget: its own default model.
    (should (eq (cmacs-gowl-bar-ai--provider "ollama") 'ollama))
    (should (null (cmacs-gowl-bar-ai--model "ollama" "")))
    (should (equal (cmacs-gowl-bar-ai--model "ollama" "qwen3") "qwen3"))
    ;; A provider customised for the bar: also not "sonnet".
    (let ((cmacs-gowl-bar-ai-provider 'ollama))
      (should (eq (cmacs-gowl-bar-ai--provider "") 'ollama))
      (should (null (cmacs-gowl-bar-ai--model "" ""))))
    (let ((cmacs-gowl-bar-ai-model "haiku"))
      (should (equal (cmacs-gowl-bar-ai--model nil nil) "haiku")))))

(ert-deftest cmacs-gowl-bar-ai-test-long-answers-are-cut ()
  "An answer longer than the cap is cut, with a note saying so."
  (let ((cmacs-gowl-bar-ai-max-chars 10))
    (should (string-prefix-p "0123456789\n[... cut"
                             (cmacs-gowl-bar-ai--clip "0123456789abcdef")))
    (should (equal (cmacs-gowl-bar-ai--clip "short") "short"))))

(ert-deftest cmacs-gowl-bar-ai-test-provider-list ()
  "Named OpenAI-compatible endpoints are providers too."
  (let ((cmacs-ai-openai-compatible-endpoints
         '((my-vllm :url "http://localhost:8000/v1")))
        pushed)
    (cl-letf (((symbol-function 'cmacs-ai-providers)
               (lambda (&rest _) '(claude ollama)))
              (cmacs-gowl-bar-push-function (lambda (a) (setq pushed a))))
      (should (equal (cmacs-gowl-bar-ai-provider-names)
                     '("claude" "ollama" "my-vllm")))
      (cmacs-gowl-bar-ai-push-providers "ai-assistant")
      (should (equal (cdr (assoc "ai-assistant.ai-providers" pushed))
                     "claude,ollama,my-vllm")))))

(provide 'cmacs-gowl-bar-ai-tests)

;;; cmacs-gowl-bar-ai-tests.el ends here
