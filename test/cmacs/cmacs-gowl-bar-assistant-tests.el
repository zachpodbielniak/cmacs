;;; cmacs-gowl-bar-assistant-tests.el --- Tests for the ai-assistant bar glue  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The cmacs half of gowl's `ai-assistant' widget.  gowl's
;; tests/test-bar-ai-assistant.c holds the other half: it builds the
;; exact `emacsctl eval' line for "In cmacs" and reads the settings
;; pushed here, so a rename on either side fails one of the two.
;;
;; No bar, no model, no chat buffer: `cmacs-gowl-bar-push-function',
;; `cmacs-gowl-bar-assistant-list-models-function' and
;; `cmacs-gowl-bar-assistant-open-chat-function' are rebound, and
;; `cmacs-ai-providers' is stubbed with &rest (the ERT stub arity trap).
;;
;; What these catch:
;;
;;   - the push not telling the widget it is under cmacs, or reaching
;;     only the top bar;
;;   - model listing -- synchronous in cmacs-ai -- running inside the
;;     push instead of from an idle timer (a frozen desktop at startup);
;;   - an HTTP provider being listed by default, or a failing provider
;;     stopping the others, or a comma in a model name breaking the list;
;;   - open-in-chat opening the buffer synchronously from emacsctl, or
;;     signalling, or taking an unknown provider symbol from the bar;
;;   - the form gowl generates not reading back as the call it means.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-bar-ai)
(require 'cmacs-gowl-bar-assistant)
;; Loaded now, not by the code under test: a `require' inside a test
;; would redefine what the test has just stubbed.
(require 'cmacs-ai nil t)
(require 'cmacs-ai-chat nil t)

(defmacro cmacs-gowl-bar-assistant-tests--with (pushes &rest body)
  "Run BODY recording every pushed alist in PUSHES, oldest first.
cmacs-ai offers claude, ollama, claude-code and opencode."
  (declare (indent 1))
  `(let ((,pushes nil)
         (cmacs-gowl-bar-assistant--model-timer nil))
     (cl-letf* ((cmacs-gowl-bar-push-function
                 (lambda (alist) (setq ,pushes (append ,pushes (list alist)))))
                ((symbol-function 'cmacs-ai-providers)
                 (lambda (&rest _) '(claude ollama claude-code opencode))))
       (unwind-protect
           (progn ,@body)
         (when (timerp cmacs-gowl-bar-assistant--model-timer)
           (cancel-timer cmacs-gowl-bar-assistant--model-timer))))))

(defun cmacs-gowl-bar-assistant-tests--all (pushes)
  "Every pushed key/value pair in PUSHES, in order."
  (apply #'append pushes))

(defun cmacs-gowl-bar-assistant-tests--get (pushes key)
  "The last value pushed for KEY in PUSHES."
  (cdr (assoc key (reverse (cmacs-gowl-bar-assistant-tests--all pushes)))))

(ert-deftest cmacs-gowl-bar-assistant-test-push-says-cmacs ()
  "The widget is told it runs inside cmacs, in both bars, with providers."
  (cmacs-gowl-bar-assistant-tests--with pushes
    (let ((cmacs-gowl-bar-ai-provider 'claude-code)
          (cmacs-gowl-bar-ai-model "sonnet"))
      (should (null (cmacs-gowl-bar-assistant-push))))
    (should (equal (cmacs-gowl-bar-assistant-tests--get
                    pushes "ai-assistant.ai-backend")
                   "cmacs"))
    (should (equal (cmacs-gowl-bar-assistant-tests--get
                    pushes "bottom-ai-assistant.ai-backend")
                   "cmacs"))
    (should (equal (cmacs-gowl-bar-assistant-tests--get
                    pushes "ai-assistant.ai-default-model")
                   "sonnet"))
    (should (equal (cmacs-gowl-bar-assistant-tests--get
                    pushes "ai-assistant.ai-default-provider")
                   "claude-code"))
    (should (string-match-p
             "claude-code"
             (cmacs-gowl-bar-assistant-tests--get
              pushes "ai-assistant.ai-providers")))))

(ert-deftest cmacs-gowl-bar-assistant-test-push-does-not-list-models ()
  "Listing is synchronous, so the push only schedules it."
  (cmacs-gowl-bar-assistant-tests--with pushes
    (let* ((listed nil)
           (cmacs-gowl-bar-assistant-list-models-function
            (lambda (p) (push p listed) '("m1"))))
      (cmacs-gowl-bar-assistant-push)
      (should (null listed))
      (should (timerp cmacs-gowl-bar-assistant--model-timer))
      (should-not (assoc "ai-assistant.models.claude-code"
                         (cmacs-gowl-bar-assistant-tests--all pushes))))))

(ert-deftest cmacs-gowl-bar-assistant-test-model-lists ()
  "Offered CLI providers are listed; failures and commas are contained."
  (cmacs-gowl-bar-assistant-tests--with pushes
    (let* ((listed nil)
           (cmacs-gowl-bar-assistant-model-list-providers
            '(claude-code opencode cursor))
           (cmacs-gowl-bar-assistant-list-models-function
            (lambda (p)
              (push p listed)
              (pcase p
                ('claude-code '("sonnet" "opus" "bad,name" "" haiku))
                ('opencode (error "opencode is not installed"))
                (_ '("never"))))))
      (cmacs-gowl-bar-assistant--push-model-lists)
      ;; cursor is not offered by this build: not even asked.
      (should (equal (sort listed (lambda (a b) (string< a b)))
                     '(claude-code opencode)))
      (should (equal (cmacs-gowl-bar-assistant-tests--get
                      pushes "ai-assistant.models.claude-code")
                     "sonnet,opus,haiku"))
      (should (equal (cmacs-gowl-bar-assistant-tests--get
                      pushes "bottom-ai-assistant.models.claude-code")
                     "sonnet,opus,haiku"))
      (should-not (assoc "ai-assistant.models.opencode"
                         (cmacs-gowl-bar-assistant-tests--all pushes))))))

(ert-deftest cmacs-gowl-bar-assistant-test-default-lists-only-cli ()
  "No HTTP provider is listed by default: that would be network I/O on
the compositor's thread."
  (dolist (p '(claude openai gemini grok ollama openai-compatible))
    (should-not (memq p cmacs-gowl-bar-assistant-model-list-providers))))

(ert-deftest cmacs-gowl-bar-assistant-test-open-is-deferred ()
  "open-in-chat returns t before any buffer exists."
  (let ((opened nil)
        (timers-before (copy-sequence timer-list)))
    (cl-letf (((symbol-function 'cmacs-ai-providers)
               (lambda (&rest _) '(claude ollama))))
      (let ((cmacs-gowl-bar-assistant-open-chat-function
             (lambda (&rest args) (push args opened) nil)))
        (should (eq t (cmacs-gowl-bar-assistant-open-in-chat
                       "ollama" "qwen3:8b" "User: hi")))
        (should (null opened))
        ;; Clean up the timer this scheduled.
        (dolist (tm timer-list)
          (unless (memq tm timers-before)
            (cancel-timer tm)))))))

(ert-deftest cmacs-gowl-bar-assistant-test-open-seeds-compose ()
  "The chat opens with the bar's provider and model, transcript composed."
  (let ((args nil)
        (buf (generate-new-buffer " *assistant-test-chat*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cmacs-ai-providers)
                   (lambda (&rest _) '(claude ollama))))
          (let ((cmacs-gowl-bar-assistant-send-on-open nil)
                (cmacs-gowl-bar-assistant-open-chat-function
                 (lambda (&rest a) (setq args a) buf)))
            (with-current-buffer buf (insert "* Compose\n"))
            (should (eq buf (cmacs-gowl-bar-assistant--open
                             "ollama" "qwen3:8b"
                             "User: hi\n\nAssistant: hello")))
            (should (equal args '(ollama "qwen3:8b")))
            (with-current-buffer buf
              (should (string-suffix-p
                       (concat cmacs-gowl-bar-assistant-seed-header
                               "User: hi\n\nAssistant: hello")
                       (buffer-string))))))
      (kill-buffer buf))))

(ert-deftest cmacs-gowl-bar-assistant-test-open-refuses-unknown-provider ()
  "A provider name this cmacs-ai does not offer becomes the default."
  (let ((args 'unset))
    (cl-letf (((symbol-function 'cmacs-ai-providers)
               (lambda (&rest _) '(claude))))
      (let ((cmacs-gowl-bar-assistant-open-chat-function
             (lambda (&rest a) (setq args a) nil)))
        (cmacs-gowl-bar-assistant--open "no-such-thing" "" nil)
        (should (equal args '(nil nil)))))))

(ert-deftest cmacs-gowl-bar-assistant-test-open-never-signals ()
  "A chat that fails to open is a message, not an error."
  (cl-letf (((symbol-function 'cmacs-ai-providers)
             (lambda (&rest _) '(claude))))
    (let ((cmacs-gowl-bar-assistant-open-chat-function
           (lambda (&rest _) (error "cmacs-ai not built"))))
      (should (null (cmacs-gowl-bar-assistant--open "claude" nil "x"))))))

(ert-deftest cmacs-gowl-bar-assistant-test-gowl-form-reads-back ()
  "The form gowl builds (bar_assistant_cmacs_open_cmdline) is the call."
  (let* ((text "(cmacs-gowl-bar-assistant-open-in-chat \"ollama\" nil \"User: it's \\\"quoted\\\") (kill-emacs)\\\\\n\nAssistant: ok\")")
         (form (car (read-from-string text))))
    (should (eq (car form) 'cmacs-gowl-bar-assistant-open-in-chat))
    (should (equal (cdr form)
                   '("ollama" nil
                     "User: it's \"quoted\") (kill-emacs)\\\n\nAssistant: ok")))))

(provide 'cmacs-gowl-bar-assistant-tests)

;;; cmacs-gowl-bar-assistant-tests.el ends here
