;;; cmacs-gowl-ai-field-tests.el --- Tests for AI commands on foreign text fields -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gowl-ai-field' reads another application's text field, has a
;; model rewrite it and writes the answer back.  What can go wrong in
;; it is policy and sequencing, and that is what is tested here, against
;; a fake compositor and a fake model: which action runs, whether the
;; selection or the whole field is sent, that the answer is written
;; once and only into the window that was asked about, that a denied,
;; withheld or password field never reaches the model, and that undo
;; and cancel leave things as they say.
;;
;; Nothing here touches a compositor, a model or the network.  Every
;; stub of a C DEFUN takes `&rest': a stub with a fixed arity breaks
;; under `make check-cmacs' the day the DEFUN gains an argument.
;;
;; Timers do not run by themselves in a test: what one would have run
;; is recorded, and fired by hand with `--fire'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs nil t)
;; Loaded here, outside the `features' binding the fixture makes, so
;; that the code under test finds them loaded.
(require 'cmacs-ai nil t)
(require 'cmacs-ai-textops nil t)
(require 'cmacs-gowl-edit-field)
(require 'cmacs-gowl-ai-field)

;; The redaction rules are faked here (`cmacs-redact-window' is stubbed
;; in the fixture), so the code under test's `require' must succeed
;; whether or not the real library is in the tree this runs in.
(unless (locate-library "cmacs-redact")
  (provide 'cmacs-redact))

(defvar cmacs-gowl-focus-changed-functions)
(defvar cmacs-gowl-client-removed-functions)
(defvar cmacs-ai-proofread-system-prompt)
(defvar cmacs-ai-rephrase-system-prompt)

;;;; A fake compositor and a fake model

(defvar cmacs-gowl-ai-field-tests--calls nil
  "What the code under test asked of the fakes, newest first.")

(defvar cmacs-gowl-ai-field-tests--focused 'origin
  "The window the fake compositor says holds the keyboard.")

(defvar cmacs-gowl-ai-field-tests--clients
  '((origin . ((id . 7) (title . "Reply - Browser") (app-id . "librewolf")
               (embedded . nil)))
    (other . ((id . 9) (title . "Terminal") (app-id . "gst")
              (embedded . nil))))
  "The fake compositor's windows, an alist of (CLIENT . INFO).")

(defvar cmacs-gowl-ai-field-tests--card t
  "Non-nil when the fake compositor has a menu card.")

(defvar cmacs-gowl-ai-field-tests--card-answer "pending"
  "What the fake menu card says of its choice: the tail of `menu-choice'.")

(defvar cmacs-gowl-ai-field-tests--redact t
  "What the fake `cmacs-redact-window' does: t shows, nil withholds,
`error' signals.")

(defvar cmacs-gowl-ai-field-tests--said nil
  "The toasts and messages shown, newest first.")

(defun cmacs-gowl-ai-field-tests--called (name)
  "Return the argument lists of the recorded calls to NAME, oldest first."
  (nreverse (cl-loop for (n . args) in cmacs-gowl-ai-field-tests--calls
                     when (eq n name) collect args)))

(defun cmacs-gowl-ai-field-tests--record (name)
  "Return a stub that records its call as NAME and returns `pending'."
  (lambda (&rest args)
    (push (cons name args) cmacs-gowl-ai-field-tests--calls)
    'pending))

(defmacro cmacs-gowl-ai-field-tests--with (&rest body)
  "Run BODY against the fakes, with the window `origin' focused."
  (declare (indent 0) (debug t))
  `(let ((cmacs-gowl-ai-field-tests--calls nil)
         (cmacs-gowl-ai-field-tests--focused 'origin)
         (cmacs-gowl-ai-field-tests--clients
          (copy-tree cmacs-gowl-ai-field-tests--clients))
         (cmacs-gowl-ai-field-tests--card t)
         (cmacs-gowl-ai-field-tests--card-answer "pending")
         (cmacs-gowl-ai-field-tests--redact t)
         (cmacs-gowl-ai-field-tests--said nil)
         (cmacs-gowl-ai-field--job nil)
         (cmacs-gowl-ai-field--last nil)
         (cmacs-gowl-ai-field--bound-keys nil)
         (cmacs-gowl-ai-field-chooser 'card)
         (cmacs-gowl-ai-field-provider nil)
         (cmacs-gowl-ai-field-model nil)
         (cmacs-gowl-ai-field-clipboard-fallback t)
         (cmacs-gowl-edit-field--sessions nil)
         (cmacs-gowl-edit-field--waiters nil)
         (cmacs-gowl-edit-field-verify t)
         (cmacs-gowl-focus-changed-functions nil)
         (cmacs-gowl-client-removed-functions nil)
         (delete-frame-functions nil)
         (kill-ring nil))
     (cl-letf* (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
                ((symbol-function 'gowl-focused-client)
                 (lambda (&rest _) cmacs-gowl-ai-field-tests--focused))
                ((symbol-function 'gowl-focus-client)
                 (lambda (&rest args)
                   (push (cons 'focus args) cmacs-gowl-ai-field-tests--calls)
                   t))
                ((symbol-function 'gowl-list-clients)
                 (lambda (&rest _)
                   (mapcar #'car cmacs-gowl-ai-field-tests--clients)))
                ((symbol-function 'gowl-client-info)
                 (lambda (&rest args)
                   (alist-get (car args)
                              cmacs-gowl-ai-field-tests--clients)))
                ((symbol-function 'gowl-client-pid) (lambda (&rest _) 4242))
                ((symbol-function 'gowl-text-field-read)
                 (cmacs-gowl-ai-field-tests--record 'read))
                ((symbol-function 'gowl-text-field-replace)
                 (cmacs-gowl-ai-field-tests--record 'replace))
                ((symbol-function 'gowl-text-field-send-key)
                 (cmacs-gowl-ai-field-tests--record 'key))
                ((symbol-function 'gowl-clipboard-get)
                 (lambda (&rest _) "the user's clipboard"))
                ((symbol-function 'gowl-clipboard-set-transient)
                 (cmacs-gowl-ai-field-tests--record 'clipboard))
                ((symbol-function 'gowl-add-keybind)
                 (cmacs-gowl-ai-field-tests--record 'bind))
                ((symbol-function 'gowl-remove-keybind)
                 (cmacs-gowl-ai-field-tests--record 'unbind))
                ((symbol-function 'gowl-run-command)
                 (lambda (&rest args)
                   (push (cons 'command args)
                         cmacs-gowl-ai-field-tests--calls)
                   (let ((line (car args)))
                     (cond
                      ((not cmacs-gowl-ai-field-tests--card) nil)
                      ((string-prefix-p "menu-choose " line) "OK tok1")
                      ((string-prefix-p "menu-choice " line)
                       (concat "OK tok1 "
                               cmacs-gowl-ai-field-tests--card-answer))))))
                ((symbol-function 'gowl-bar-notify)
                 (lambda (&rest args)
                   (push (mapconcat #'identity (delq nil (copy-sequence args))
                                    " | ")
                         cmacs-gowl-ai-field-tests--said)
                   "OK"))
                ((symbol-function 'cmacs-redact-window)
                 (lambda (&rest args)
                   (push (cons 'redact args) cmacs-gowl-ai-field-tests--calls)
                   (pcase cmacs-gowl-ai-field-tests--redact
                     ('error (error "Rules failed to load"))
                     ('nil nil)
                     (_ (cons (nth 0 args) (nth 1 args))))))
                ((symbol-function 'cmacs-ai--ensure) (lambda (&rest _) t))
                ((symbol-function 'cmacs-ai-make-session)
                 (lambda (&rest args)
                   (push (cons 'session args)
                         cmacs-gowl-ai-field-tests--calls)
                   (cons 11 22)))
                ((symbol-function 'cmacs-ai-chat-stream)
                 (cmacs-gowl-ai-field-tests--record 'stream))
                ((symbol-function 'cmacs-ai-chat-cancel)
                 (cmacs-gowl-ai-field-tests--record 'cancel))
                ((symbol-function 'cmacs-ai-free-session)
                 (cmacs-gowl-ai-field-tests--record 'free))
                ((symbol-function 'run-at-time)
                 (lambda (&rest args)
                   (push (cons 'timer (cddr args))
                         cmacs-gowl-ai-field-tests--calls)
                   nil))
                ((symbol-function 'message)
                 (lambda (&rest args)
                   (when (car args)
                     (push (apply #'format-message args)
                           cmacs-gowl-ai-field-tests--said))
                   nil)))
       ,@body)))

(defun cmacs-gowl-ai-field-tests--ok (text cursor &optional anchor partial)
  "Return a successful read of TEXT with CURSOR and ANCHOR, in bytes."
  (list :status 'ok :text text :cursor cursor :anchor (or anchor cursor)
        :complete (not partial) :hint 0 :purpose 0))

(defun cmacs-gowl-ai-field-tests--answer (name result)
  "Call the callback of the last recorded call to NAME with RESULT."
  (let ((args (car (last (cmacs-gowl-ai-field-tests--called name)))))
    (funcall (car (last args)) result)))

(defun cmacs-gowl-ai-field-tests--fire (function)
  "Run the newest recorded timer whose function is FUNCTION.
A timer is run once: it is taken off the record first."
  (let ((cell (cl-find-if (lambda (c)
                            (and (eq (car c) 'timer) (eq (cadr c) function)))
                          cmacs-gowl-ai-field-tests--calls)))
    (should cell)
    (setq cmacs-gowl-ai-field-tests--calls
          (delq cell cmacs-gowl-ai-field-tests--calls))
    (apply (cadr cell) (cddr cell))))

(defun cmacs-gowl-ai-field-tests--pick (index)
  "Have the fake menu card answer with the row INDEX, or nil to cancel."
  (setq cmacs-gowl-ai-field-tests--card-answer
        (if index (format "chosen %d" index) "cancelled"))
  (cmacs-gowl-ai-field-tests--fire #'cmacs-gowl-ai-field--card-poll))

(defun cmacs-gowl-ai-field-tests--model (&rest payloads)
  "Deliver PAYLOADS, stream events, to the last model request."
  (let ((callback (car (last (car (last (cmacs-gowl-ai-field-tests--called
                                         'stream)))))))
    (dolist (payload payloads)
      (funcall callback payload))))

(defun cmacs-gowl-ai-field-tests--prompt ()
  "Return the prompt of the last model request."
  (nth 1 (car (last (cmacs-gowl-ai-field-tests--called 'stream)))))

(defun cmacs-gowl-ai-field-tests--said-p (regexp)
  "Return non-nil if something matching REGEXP was said to the user."
  (cl-some (lambda (s) (string-match-p regexp s))
           cmacs-gowl-ai-field-tests--said))

(defun cmacs-gowl-ai-field-tests--apply-replace (old cursor args)
  "Return OLD after the edit ARGS, a recorded replace, at byte CURSOR.
The edit is applied the way an application would, byte for byte."
  (let* ((bytes (encode-coding-string old 'utf-8 t))
         (before (nth 1 args))
         (after (nth 2 args)))
    (decode-coding-string
     (concat (substring bytes 0 (- cursor before))
             (encode-coding-string (nth 3 args) 'utf-8 t)
             (substring bytes (+ cursor after)))
     'utf-8 t)))

(defun cmacs-gowl-ai-field-tests--proofread (text answer &optional cursor anchor)
  "Run the proofread action on a field holding TEXT; the model says ANSWER.
CURSOR and ANCHOR are the field's, in bytes.  Stops with the answer
delivered: what happens to it is for the caller to look at."
  (cmacs-gowl-ai-field-proofread)
  (cmacs-gowl-ai-field-tests--answer
   'read (cmacs-gowl-ai-field-tests--ok text (or cursor 0) anchor))
  (cmacs-gowl-ai-field-tests--model (list :delta answer) (list :end)))

;;;; Pure helpers

(ert-deftest cmacs-gowl-ai-field-test-subject ()
  "The selection is acted on when there is one, else everything."
  (should (equal '(0 . 5) (cmacs-gowl-ai-field--subject "hello" 2 2)))
  (should (equal '(1 . 3) (cmacs-gowl-ai-field--subject "hello" 1 3)))
  ;; A selection made backwards is the same selection.
  (should (equal '(1 . 3) (cmacs-gowl-ai-field--subject "hello" 3 1)))
  ;; No cursor known (the clipboard fallback): everything.
  (should (equal '(0 . 5) (cmacs-gowl-ai-field--subject "hello" nil nil)))
  ;; Offsets an application got wrong do not reach past the text.
  (should (equal '(2 . 5) (cmacs-gowl-ai-field--subject "hello" 2 99))))

(ert-deftest cmacs-gowl-ai-field-test-splice ()
  "The answer replaces exactly the part that was sent."
  (should (equal "a NEW c" (cmacs-gowl-ai-field--splice "a old c" 2 5 "NEW")))
  (should (equal "NEW" (cmacs-gowl-ai-field--splice "old" 0 3 "NEW"))))

(ert-deftest cmacs-gowl-ai-field-test-provider-and-model ()
  "The text commands' provider and model are used unless overridden."
  (let ((cmacs-ai-textops-provider 'claude-code)
        (cmacs-ai-textops-model "sonnet"))
    (let ((cmacs-gowl-ai-field-provider nil)
          (cmacs-gowl-ai-field-model nil))
      (should (equal '(claude-code . "sonnet")
                     (cmacs-gowl-ai-field--provider+model))))
    (let ((cmacs-gowl-ai-field-provider nil)
          (cmacs-gowl-ai-field-model "haiku"))
      (should (equal '(claude-code . "haiku")
                     (cmacs-gowl-ai-field--provider+model))))
    ;; Another provider does not inherit a model that is not its own.
    (let ((cmacs-gowl-ai-field-provider 'ollama)
          (cmacs-gowl-ai-field-model nil))
      (should (equal '(ollama) (cmacs-gowl-ai-field--provider+model))))))

(ert-deftest cmacs-gowl-ai-field-test-requests-reuse-the-text-operations ()
  "An action's prompts are cmacs-ai-textops.el's, not copies of them."
  (skip-unless (featurep 'cmacs-ai-textops))
  (let ((cmacs-ai-proofread-system-prompt "PROOF SYSTEM")
        (cmacs-ai-rephrase-system-prompt "REPHRASE SYSTEM")
        (cmacs-gowl-ai-field-translate-language "German"))
    (let ((request (cmacs-gowl-ai-field--request 'proofread "teh cat" nil)))
      (should (equal "PROOF SYSTEM" (car request)))
      (should (string-suffix-p "teh cat" (cdr request))))
    (let ((request (cmacs-gowl-ai-field--request 'shorten "long text" nil)))
      (should (equal "REPHRASE SYSTEM" (car request)))
      (should (string-match-p "How: Make it substantially shorter"
                              (cdr request))))
    (should (string-match-p
             "How: Translate it into German"
             (cdr (cmacs-gowl-ai-field--request 'translate "hi" nil))))
    ;; An instruction given wins over the action's own.
    (should (string-match-p
             "How: as a haiku"
             (cdr (cmacs-gowl-ai-field--request 'custom "hi" "as a haiku"))))
    ;; A system prompt of the user's own wins over the operation's.
    (let ((cmacs-gowl-ai-field-actions
           '((mine :label "Mine" :op rephrase :system "MY SYSTEM"))))
      (should (equal "MY SYSTEM"
                     (car (cmacs-gowl-ai-field--request 'mine "x" nil)))))
    (should-error (cmacs-gowl-ai-field--request 'no-such-action "x" nil))))

(ert-deftest cmacs-gowl-ai-field-test-shipped-actions-are-sound ()
  "Every shipped action names a text operation that exists."
  (skip-unless (featurep 'cmacs-ai-textops))
  (dolist (action cmacs-gowl-ai-field-actions)
    (should (stringp (plist-get (cdr action) :label)))
    (should (consp (cmacs-gowl-ai-field--request (car action) "x" "how")))))

;;;; Choosing an action

(ert-deftest cmacs-gowl-ai-field-test-chooser-uses-the-menu-card ()
  "The actions are listed on the compositor's card, and the pick runs."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (let ((cmacs-ai-proofread-system-prompt "PROOF SYSTEM"))
      (cmacs-gowl-ai-field)
      ;; Nothing is offered before the field has been read.
      (should-not (cmacs-gowl-ai-field-tests--called 'command))
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok "teh cat" 7))
      (let ((line (caar (cmacs-gowl-ai-field-tests--called 'command))))
        (should (string-prefix-p "menu-choose AI on this field\t" line))
        (should (equal (mapcar (lambda (a) (plist-get (cdr a) :label))
                               cmacs-gowl-ai-field-actions)
                       (cdr (split-string line "\t")))))
      (should-not (cmacs-gowl-ai-field-tests--called 'session))
      ;; Still pending: asked again, nothing run.
      (cmacs-gowl-ai-field-tests--fire #'cmacs-gowl-ai-field--card-poll)
      (should-not (cmacs-gowl-ai-field-tests--called 'session))
      (cmacs-gowl-ai-field-tests--pick 0)
      (should (equal "PROOF SYSTEM"
                     (nth 2 (car (cmacs-gowl-ai-field-tests--called
                                  'session)))))
      (should (string-suffix-p "teh cat" (cmacs-gowl-ai-field-tests--prompt)))
      ;; No Emacs frame was asked for the keyboard.
      (should-not (cmacs-gowl-ai-field-tests--called 'focus)))))

(ert-deftest cmacs-gowl-ai-field-test-chooser-cancelled ()
  "A card closed without a pick ends the job and lets the field go."
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "text" 0))
    (should cmacs-gowl-edit-field--sessions)
    (cmacs-gowl-ai-field-tests--pick nil)
    (should-not cmacs-gowl-ai-field--job)
    (should-not cmacs-gowl-edit-field--sessions)
    (should-not (cmacs-gowl-ai-field-tests--called 'session))))

(ert-deftest cmacs-gowl-ai-field-test-chooser-falls-back-to-minibuffer ()
  "With no menu card the choice is read in the minibuffer frame."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (setq cmacs-gowl-ai-field-tests--card nil)
    (let ((asked nil))
      (cl-letf (((symbol-function 'cmacs-gowl-ai-field--read-choice)
                 (lambda (&rest args) (setq asked args) 1)))
        (cmacs-gowl-ai-field)
        (cmacs-gowl-ai-field-tests--answer
         'read (cmacs-gowl-ai-field-tests--ok "some text" 0))
        ;; The read is deferred to a timer, never done inside the
        ;; compositor's callback.
        (should-not asked)
        (let ((cell (cl-find 'timer cmacs-gowl-ai-field-tests--calls
                             :key #'car)))
          (funcall (cadr cell)))
        (should (equal "AI on this field" (car asked)))
        (should (eq 'rewrite
                    (cmacs-gowl-ai-field--job-action
                     cmacs-gowl-ai-field--job)))
        (should (cmacs-gowl-ai-field-tests--called 'stream))))))

(ert-deftest cmacs-gowl-ai-field-test-direct-command-skips-the-chooser ()
  "A direct command runs its action with no menu at all."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-shorten)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "a long text" 0))
    (should-not (cmacs-gowl-ai-field-tests--called 'command))
    (should (string-match-p "How: Make it substantially shorter"
                            (cmacs-gowl-ai-field-tests--prompt)))))

(ert-deftest cmacs-gowl-ai-field-test-custom-asks-for-the-instruction ()
  "The free-form action reads its instruction, then hands focus back."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cl-letf (((symbol-function 'cmacs-gowl-ai-field--read-instruction)
               (lambda (&rest _) "as a haiku")))
      (cmacs-gowl-ai-field-custom)
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok "hello" 0))
      (should (string-match-p "How: as a haiku"
                              (cmacs-gowl-ai-field-tests--prompt)))
      (should (equal '((origin))
                     (cmacs-gowl-ai-field-tests--called 'focus))))
    ;; Given the instruction up front, nothing is asked.
    (cmacs-gowl-ai-field-cancel)
    (setq cmacs-gowl-ai-field-tests--calls nil)
    (cl-letf (((symbol-function 'cmacs-gowl-ai-field--read-instruction)
               (lambda (&rest _) (error "Asked anyway"))))
      (cmacs-gowl-ai-field-custom "in pirate speak")
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok "hello" 0))
      (should (string-match-p "How: in pirate speak"
                              (cmacs-gowl-ai-field-tests--prompt))))))

(ert-deftest cmacs-gowl-ai-field-test-custom-with-no-instruction ()
  "An instruction not given is a cancel, not a default rewrite."
  (cmacs-gowl-ai-field-tests--with
    (cl-letf (((symbol-function 'cmacs-gowl-ai-field--read-instruction)
               (lambda (&rest _) nil)))
      (cmacs-gowl-ai-field-custom)
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok "hello" 0))
      (should-not (cmacs-gowl-ai-field-tests--called 'stream))
      (should-not cmacs-gowl-ai-field--job)
      (should-not cmacs-gowl-edit-field--sessions))))

;;;; Selection against the whole field

(ert-deftest cmacs-gowl-ai-field-test-whole-field ()
  "With nothing selected the whole text is sent and the whole replaced."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-tests--proofread "teh cat sat" "The cat sat." 4)
    (should (string-suffix-p "\n\nteh cat sat"
                             (cmacs-gowl-ai-field-tests--prompt)))
    ;; The field is read again before it is written.
    (should (= 2 (length (cmacs-gowl-ai-field-tests--called 'read))))
    (should-not (cmacs-gowl-ai-field-tests--called 'replace))
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh cat sat" 4))
    (let ((edit (car (cmacs-gowl-ai-field-tests--called 'replace))))
      (should (eq 'origin (car edit)))
      (should (equal "The cat sat."
                     (cmacs-gowl-ai-field-tests--apply-replace
                      "teh cat sat" 4 edit))))
    ;; Written once.
    (should (= 1 (length (cmacs-gowl-ai-field-tests--called 'replace))))
    (cmacs-gowl-ai-field-tests--answer 'replace t)
    (should-not cmacs-gowl-ai-field--job)
    (should-not cmacs-gowl-edit-field--sessions)
    (should (cmacs-gowl-ai-field-tests--said-p "done"))))

(ert-deftest cmacs-gowl-ai-field-test-selection-only ()
  "A selection is all that is sent, and all that is replaced."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    ;; "héllo wrld there": é is two bytes, so "wrld" is bytes 7..11.
    (let ((text "héllo wrld there"))
      (cmacs-gowl-ai-field-tests--proofread text "world" 11 7)
      (should (string-suffix-p "\n\nwrld" (cmacs-gowl-ai-field-tests--prompt)))
      (should-not (string-match-p "there"
                                  (cmacs-gowl-ai-field-tests--prompt)))
      (should (cmacs-gowl-ai-field-tests--said-p "the selection"))
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok text 11 7))
      (let ((edit (car (cmacs-gowl-ai-field-tests--called 'replace))))
        (should (equal "héllo world there"
                       (cmacs-gowl-ai-field-tests--apply-replace
                        text 11 edit)))
        ;; And no more of the field than the selection was touched.
        (should (<= (+ (nth 1 edit) (nth 2 edit)) 4))))))

(ert-deftest cmacs-gowl-ai-field-test-clipboard-fallback-is-whole-field ()
  "Through the clipboard there is no selection: the whole text is sent."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cl-letf (((symbol-function 'gowl-text-field-read)
               (lambda (&rest _) (error "No text input")))
              ((symbol-function 'gowl-clipboard-get)
               (lambda (&rest _) "all of teh field")))
      (cmacs-gowl-ai-field-proofread)
      (cmacs-gowl-ai-field-tests--fire
       #'cmacs-gowl-edit-field--clipboard-collect)
      (should (string-suffix-p "\n\nall of teh field"
                               (cmacs-gowl-ai-field-tests--prompt)))
      ;; With the fallback off, the same window is refused.
      (cmacs-gowl-ai-field-cancel)
      (setq cmacs-gowl-ai-field-tests--calls nil)
      (let ((cmacs-gowl-ai-field-clipboard-fallback nil))
        (cmacs-gowl-ai-field-proofread)
        (should-not (cmacs-gowl-ai-field-tests--called 'key))
        (should-not (cmacs-gowl-ai-field-tests--called 'stream))
        (should-not cmacs-gowl-ai-field--job)))))

(ert-deftest cmacs-gowl-ai-field-test-non-streaming-provider ()
  "A provider that answers all at once is written just the same."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh" 0))
    (cmacs-gowl-ai-field-tests--model (list :end :text "```\nthe\n```"))
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh" 0))
    ;; And the fence the model added against orders is not typed.
    (should (equal "the"
                   (cmacs-gowl-ai-field-tests--apply-replace
                    "teh" 0
                    (car (cmacs-gowl-ai-field-tests--called 'replace)))))))

(ert-deftest cmacs-gowl-ai-field-test-empty-and-oversized ()
  "An empty field and one too long for a model are not sent."
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "  \n" 0))
    (should-not (cmacs-gowl-ai-field-tests--called 'session))
    (should-not cmacs-gowl-edit-field--sessions)
    (let ((cmacs-gowl-ai-field-max-chars 10))
      (cmacs-gowl-ai-field-proofread)
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok "eleven char" 0))
      (should-not (cmacs-gowl-ai-field-tests--called 'session))
      (should (cmacs-gowl-ai-field-tests--said-p "too long")))))

;;;; Never the wrong window

(ert-deftest cmacs-gowl-ai-field-test-focus-moved ()
  "An answer that arrives after focus moved is kept, not typed."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh cat" 0))
    (setq cmacs-gowl-ai-field-tests--focused 'other)
    (cmacs-gowl-ai-field-tests--model '(:delta "the ") '(:delta "cat") '(:end))
    ;; Not read again, not written, not refocused.
    (should (= 1 (length (cmacs-gowl-ai-field-tests--called 'read))))
    (should-not (cmacs-gowl-ai-field-tests--called 'replace))
    (should-not (cmacs-gowl-ai-field-tests--called 'key))
    (should-not (cmacs-gowl-ai-field-tests--called 'focus))
    (should (equal "the cat" (car kill-ring)))
    (should (cmacs-gowl-ai-field-tests--said-p "kill ring"))
    (should-not cmacs-gowl-ai-field--job)
    (should-not cmacs-gowl-edit-field--sessions)
    ;; Nothing was changed, so there is nothing to undo.
    (should-not cmacs-gowl-ai-field--last)))

(ert-deftest cmacs-gowl-ai-field-test-field-changed-meanwhile ()
  "A field edited while the model worked is not overwritten."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-tests--proofread "teh cat" "the cat")
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh cat and more" 0))
    (should-not (cmacs-gowl-ai-field-tests--called 'replace))
    (should (equal "the cat" (car kill-ring)))
    (should-not cmacs-gowl-ai-field--job)
    (should-not cmacs-gowl-edit-field--sessions)))

(ert-deftest cmacs-gowl-ai-field-test-application-refuses-the-text ()
  "An edit the application did not take leaves the answer on the kill ring."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-tests--proofread "teh" "the")
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh" 0))
    (cmacs-gowl-ai-field-tests--answer 'replace nil)
    (should (equal "the" (car kill-ring)))
    (should-not cmacs-gowl-ai-field--last)
    (should-not cmacs-gowl-ai-field--job)))

(ert-deftest cmacs-gowl-ai-field-test-window-closed-while-running ()
  "A window closed under the model: the answer still is not lost."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh" 0))
    (run-hook-with-args 'cmacs-gowl-client-removed-functions 'origin)
    (should-not cmacs-gowl-edit-field--sessions)
    (cmacs-gowl-ai-field-tests--model '(:delta "the") '(:end))
    (should-not (cmacs-gowl-ai-field-tests--called 'replace))
    (should (equal "the" (car kill-ring)))
    (should-not cmacs-gowl-ai-field--job)))

(ert-deftest cmacs-gowl-ai-field-test-model-error ()
  "A model that fails leaves the field alone and says so."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh" 0))
    (cmacs-gowl-ai-field-tests--model '(:error "HTTP 401"))
    (should-not (cmacs-gowl-ai-field-tests--called 'replace))
    (should (cmacs-gowl-ai-field-tests--said-p "HTTP 401"))
    (should-not kill-ring)
    (should-not cmacs-gowl-ai-field--job)
    (should-not cmacs-gowl-edit-field--sessions)))

;;;; Privacy

(ert-deftest cmacs-gowl-ai-field-test-denied-window ()
  "A window on the edit-field deny list is never read."
  (cmacs-gowl-ai-field-tests--with
    (setf (alist-get 'app-id (alist-get 'origin
                                        cmacs-gowl-ai-field-tests--clients))
          "org.keepassxc.KeePassXC")
    (cmacs-gowl-ai-field-proofread)
    (should-not (cmacs-gowl-ai-field-tests--called 'read))
    (should-not (cmacs-gowl-ai-field-tests--called 'key))
    (should-not (cmacs-gowl-ai-field-tests--called 'session))
    (should (cmacs-gowl-ai-field-tests--said-p "cmacs-gowl-edit-field-deny"))))

(ert-deftest cmacs-gowl-ai-field-test-redacted-window ()
  "A window the redaction rules exclude is refused before it is read."
  (cmacs-gowl-ai-field-tests--with
    (setq cmacs-gowl-ai-field-tests--redact nil)
    (cmacs-gowl-ai-field)
    ;; The rules were asked about this window: app-id, title, pid.
    (should (equal '(("librewolf" "Reply - Browser" 4242))
                   (cmacs-gowl-ai-field-tests--called 'redact)))
    (should-not (cmacs-gowl-ai-field-tests--called 'read))
    (should-not (cmacs-gowl-ai-field-tests--called 'command))
    (should-not (cmacs-gowl-ai-field-tests--called 'session))
    (should-not cmacs-gowl-ai-field--job)
    (should (cmacs-gowl-ai-field-tests--said-p "withheld"))))

(ert-deftest cmacs-gowl-ai-field-test-redaction-fails-closed ()
  "Rules that cannot be asked withhold every window."
  (cmacs-gowl-ai-field-tests--with
    (setq cmacs-gowl-ai-field-tests--redact 'error)
    (cmacs-gowl-ai-field-proofread)
    (should-not (cmacs-gowl-ai-field-tests--called 'read))
    (should-not (cmacs-gowl-ai-field-tests--called 'session)))
  ;; And so does a redaction library that is not there to load.
  (cmacs-gowl-ai-field-tests--with
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest _)
                 (if (eq feature 'cmacs-redact)
                     (signal 'file-missing '("Cannot open load file"))
                   feature))))
      (should (cmacs-gowl-ai-field--withheld-p
               '(:app-id "librewolf" :title "x" :pid 1))))))

(ert-deftest cmacs-gowl-ai-field-test-field-text-is-not-redacted ()
  "The field's own text reaches the model as it is: that was the request."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cl-letf (((symbol-function 'cmacs-redact-text)
               (lambda (&rest _) (error "The text was redacted"))))
      (cmacs-gowl-ai-field-proofread)
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok "my acount is 12345" 0))
      (should (string-suffix-p "my acount is 12345"
                               (cmacs-gowl-ai-field-tests--prompt)))
      ;; And the window's title and application do not.
      (should-not (string-match-p "Browser\\|librewolf"
                                  (cmacs-gowl-ai-field-tests--prompt))))))

(ert-deftest cmacs-gowl-ai-field-test-password-field ()
  "A field its application calls a password never reaches the model."
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (list :status 'ok :text "hunter2" :cursor 0 :anchor 0
                 :complete t :hint 0 :purpose 8))
    (should-not (cmacs-gowl-ai-field-tests--called 'session))
    ;; Not through the clipboard either.
    (should-not (cmacs-gowl-ai-field-tests--called 'key))
    (should (cmacs-gowl-ai-field-tests--said-p "password"))
    (should-not cmacs-gowl-ai-field--job))
  ;; The hidden-text hint says the same thing.
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (list :status 'ok :text "1234" :cursor 0 :anchor 0
                 :complete t :hint #x40 :purpose 0))
    (should-not (cmacs-gowl-ai-field-tests--called 'session))))

(ert-deftest cmacs-gowl-ai-field-test-emacs-frame ()
  "With the keyboard in Emacs there is no foreign field to act on."
  (cmacs-gowl-ai-field-tests--with
    (cl-letf (((symbol-function 'gowl-client-pid)
               (lambda (&rest _) (emacs-pid))))
      (cmacs-gowl-ai-field)
      (should-not (cmacs-gowl-ai-field-tests--called 'read))
      (should-not cmacs-gowl-ai-field--job))))

;;;; Undo

(defun cmacs-gowl-ai-field-tests--committed-edit ()
  "Proofread a field from \"teh cat\" to \"the cat\", all the way through."
  (cmacs-gowl-ai-field-tests--proofread "teh cat" "the cat" 7)
  (cmacs-gowl-ai-field-tests--answer
   'read (cmacs-gowl-ai-field-tests--ok "teh cat" 7))
  (cmacs-gowl-ai-field-tests--answer 'replace t)
  (setq cmacs-gowl-ai-field-tests--calls nil))

(ert-deftest cmacs-gowl-ai-field-test-undo ()
  "Undo puts the old text back while the field still holds the answer."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-tests--committed-edit)
    (should (equal "teh cat" (plist-get cmacs-gowl-ai-field--last :before)))
    (should (equal "the cat" (plist-get cmacs-gowl-ai-field--last :after)))
    (cmacs-gowl-ai-field-undo)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "the cat" 7))
    ;; The write verifies for itself, as every write does.
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "the cat" 7))
    (should (equal "teh cat"
                   (cmacs-gowl-ai-field-tests--apply-replace
                    "the cat" 7
                    (car (cmacs-gowl-ai-field-tests--called 'replace)))))
    (cmacs-gowl-ai-field-tests--answer 'replace t)
    (should-not cmacs-gowl-ai-field--last)
    (should-not cmacs-gowl-edit-field--sessions)
    (should-not (cmacs-gowl-ai-field-tests--called 'session))))

(ert-deftest cmacs-gowl-ai-field-test-undo-refuses-a-changed-field ()
  "Undo does not overwrite a field edited since; the old text is kept."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-tests--committed-edit)
    (cmacs-gowl-ai-field-undo)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "the cat sat" 11))
    (should-not (cmacs-gowl-ai-field-tests--called 'replace))
    (should (equal "teh cat" (car kill-ring)))
    (should-not cmacs-gowl-edit-field--sessions)
    ;; Still there for another try.
    (should cmacs-gowl-ai-field--last)))

(ert-deftest cmacs-gowl-ai-field-test-undo-wants-the-same-window ()
  "Undo reads nothing when another window holds the keyboard."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-undo)
    (should (cmacs-gowl-ai-field-tests--said-p "nothing to undo"))
    (cmacs-gowl-ai-field-tests--committed-edit)
    (setq cmacs-gowl-ai-field-tests--focused 'other)
    (cmacs-gowl-ai-field-undo)
    (should-not (cmacs-gowl-ai-field-tests--called 'read))
    (should (cmacs-gowl-ai-field-tests--said-p "another window"))
    (should cmacs-gowl-ai-field--last)))

(ert-deftest cmacs-gowl-ai-field-test-chooser-offers-undo ()
  "The chooser lists the undo for the window the last edit was in."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-tests--committed-edit)
    (cmacs-gowl-ai-field)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "the cat" 7))
    (let* ((line (caar (cmacs-gowl-ai-field-tests--called 'command)))
           (rows (cdr (split-string line "\t"))))
      (should (string-prefix-p "Undo: " (car (last rows))))
      (cmacs-gowl-ai-field-tests--pick (1- (length rows))))
    ;; The chooser's own read was let go; the undo made its own.
    (should (= 2 (length (cmacs-gowl-ai-field-tests--called 'read))))
    (should (= 1 (length cmacs-gowl-edit-field--sessions)))
    (should-not cmacs-gowl-ai-field--job)))

;;;; Cancel

(ert-deftest cmacs-gowl-ai-field-test-cancel ()
  "Cancelling stops the model, lets the field go and types nothing."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-cancel)
    (should (cmacs-gowl-ai-field-tests--said-p "nothing is running"))
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh cat" 0))
    (cmacs-gowl-ai-field-tests--model '(:delta "the "))
    (cmacs-gowl-ai-field-cancel)
    (should (equal '((22)) (cmacs-gowl-ai-field-tests--called 'cancel)))
    (should-not cmacs-gowl-ai-field--job)
    (should-not cmacs-gowl-edit-field--sessions)
    ;; What the model says afterwards goes nowhere.
    (cmacs-gowl-ai-field-tests--model '(:delta "cat") '(:end))
    (should (= 1 (length (cmacs-gowl-ai-field-tests--called 'read))))
    (should-not (cmacs-gowl-ai-field-tests--called 'replace))
    (should-not kill-ring)
    (should-not cmacs-gowl-ai-field--last)))

(ert-deftest cmacs-gowl-ai-field-test-key-again-offers-cancel ()
  "The chooser key, pressed while an action runs, offers to cancel it."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (cmacs-gowl-ai-field-proofread)
    (cmacs-gowl-ai-field-tests--answer
     'read (cmacs-gowl-ai-field-tests--ok "teh cat" 0))
    (cmacs-gowl-ai-field)
    ;; No second read, no second job.
    (should (= 1 (length (cmacs-gowl-ai-field-tests--called 'read))))
    (let ((line (caar (cmacs-gowl-ai-field-tests--called 'command))))
      (should (string-match-p "\tCancel: Fix spelling and grammar\t" line)))
    (cmacs-gowl-ai-field-tests--pick 1)
    (should cmacs-gowl-ai-field--job)
    (cmacs-gowl-ai-field)
    (cmacs-gowl-ai-field-tests--pick 0)
    (should-not cmacs-gowl-ai-field--job)
    (should (cmacs-gowl-ai-field-tests--called 'cancel))))

(ert-deftest cmacs-gowl-ai-field-test-timeout ()
  "A model that never answers is given up on, and the field left alone."
  (skip-unless (featurep 'cmacs-ai-textops))
  (cmacs-gowl-ai-field-tests--with
    (let ((cmacs-gowl-ai-field-timeout 30))
      (cmacs-gowl-ai-field-proofread)
      (cmacs-gowl-ai-field-tests--answer
       'read (cmacs-gowl-ai-field-tests--ok "teh cat" 0))
      (cmacs-gowl-ai-field-tests--fire #'cmacs-gowl-ai-field--timed-out)
      (should (cmacs-gowl-ai-field-tests--called 'cancel))
      (should-not cmacs-gowl-ai-field--job)
      (should-not cmacs-gowl-edit-field--sessions)
      (should (cmacs-gowl-ai-field-tests--said-p "too long")))))

;;;; The editor is not disturbed

(ert-deftest cmacs-gowl-ai-field-test-editor-and-action-do-not-collide ()
  "A window whose field an editor holds is not read a second time."
  (cmacs-gowl-ai-field-tests--with
    (cl-letf (((symbol-function 'cmacs-gowl-edit-field--show)
               (lambda (&rest _) nil)))
      (cmacs-gowl-edit-field)
      (should (= 1 (length cmacs-gowl-edit-field--sessions)))
      (cmacs-gowl-ai-field-proofread)
      (should (= 1 (length (cmacs-gowl-ai-field-tests--called 'read))))
      (should (= 1 (length cmacs-gowl-edit-field--sessions)))
      (should-not cmacs-gowl-ai-field--job)
      (should (cmacs-gowl-ai-field-tests--said-p "edited already")))))

;;;; Keys

(ert-deftest cmacs-gowl-ai-field-test-setup-binds-the-keys ()
  "Setup binds what is configured, and unbinds what it bound before."
  (cmacs-gowl-ai-field-tests--with
    (let ((cmacs-gowl-ai-field-key "Super+Ctrl+a")
          (cmacs-gowl-ai-field-undo-key nil)
          (cmacs-gowl-ai-field-cancel-key "Super+Ctrl+Shift+a")
          (cmacs-gowl-ai-field-action-keys
           '(("Super+Ctrl+g" . proofread)
             ;; Not an action: not bound, and never made into Lisp.
             ("Super+Ctrl+x" . no-such-action))))
      (should (cmacs-gowl-ai-field-setup))
      (should (equal
               '(("Super+Ctrl+a" custom "(cmacs-gowl-ai-field)")
                 ("Super+Ctrl+Shift+a" custom "(cmacs-gowl-ai-field-cancel)")
                 ("Super+Ctrl+g" custom
                  "(cmacs-gowl-ai-field-run 'proofread)"))
               (mapcar (lambda (args) (seq-take args 3))
                       (cmacs-gowl-ai-field-tests--called 'bind))))
      ;; A key taken out of the options stops working on the next call.
      (setq cmacs-gowl-ai-field-tests--calls nil)
      (let ((cmacs-gowl-ai-field-action-keys nil))
        (cmacs-gowl-ai-field-setup)
        (should (member '("Super+Ctrl+g")
                        (cmacs-gowl-ai-field-tests--called 'unbind)))
        (should (= 2 (length (cmacs-gowl-ai-field-tests--called 'bind))))))
    ;; No compositor: nothing bound, nothing signalled.
    (setq cmacs-gowl-ai-field-tests--calls nil)
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (should-not (cmacs-gowl-ai-field-setup))
      (should-not (cmacs-gowl-ai-field-tests--called 'bind)))))

(provide 'cmacs-gowl-ai-field-tests)

;;; cmacs-gowl-ai-field-tests.el ends here
