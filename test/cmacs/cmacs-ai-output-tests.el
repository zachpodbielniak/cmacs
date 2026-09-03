;;; cmacs-ai-output-tests.el --- Tests for the AI result window  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The result window every AI action that produces prose streams into,
;; and the follow-up conversation it now supports (cmacs-ai-output.el).
;;
;; No model is called: `cmacs-ai-chat-stream', `cmacs-ai-make-session'
;; and `cmacs-ai-free-session' are stubbed and their arguments recorded.
;; That is what lets the important assertion be made at all -- that a
;; follow-up goes to the SAME session object as the first answer, which
;; is the entire mechanism by which the model remembers what it said.
;;
;; Two of these guard traps rather than features:
;;
;;   * `...-answer-stays-protected-after-a-failed-edit'.  Emacs CLEARS
;;     `before-change-functions' when a function on it signals, so a
;;     guard-based protection works exactly once.  The seal is a text
;;     property for that reason and this test is what says so.
;;
;;   * `...-single-letter-keys-are-typable-in-the-compose-region'.  `q',
;;     `w' and `g' are commands while reading and letters while typing.
;;
;; No `cmacs-feature-p' guards: these must run in a per-file batch run
;; where that function is not defined.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'cmacs-ai-output)
;; Loaded here rather than inside the promotion tests: `skip-unless'
;; runs before the test body, so a `require' in the body leaves
;; `fboundp' nil and the tests SKIP silently -- which reads as green.
(require 'cmacs-ai-chat nil t)

;;;; Harness -----------------------------------------------------------

(defvar cmacs-ai-output-tests--sent nil
  "List of (SESSION . PROMPT), newest first, from the stubbed stream.")

(defvar cmacs-ai-output-tests--freed nil
  "Session pairs the stub was asked to free, newest first.")

(defvar cmacs-ai-output-tests--made nil
  "Session pairs the stub created, newest first.")

(defvar cmacs-ai-output-tests--appended nil
  "List of (SESSION ROLE TEXT) seeded into a lazily-made session.")

(defvar cmacs-ai-output-tests--reply "SECOND-ANSWER"
  "What the stubbed model says when a follow-up is sent.")

(defmacro cmacs-ai-output-tests--with-stubs (&rest body)
  "Run BODY with the model, session and window machinery stubbed out."
  (declare (indent 0) (debug t))
  `(let ((cmacs-ai-output-tests--sent nil)
         (cmacs-ai-output-tests--freed nil)
         (cmacs-ai-output-tests--made nil)
         (cmacs-ai-output-tests--appended nil)
         (cmacs-ai-output-followup t))
     (cl-letf (((symbol-function 'cmacs-ai-free-session)
                (lambda (pair) (push pair cmacs-ai-output-tests--freed)))
               ((symbol-function 'cmacs-ai-chat-cancel) (lambda (_) nil))
               ((symbol-function 'cmacs-ai-make-session)
                (lambda (&rest _)
                  (let ((pair (cons (gensym "client") (gensym "session"))))
                    (push pair cmacs-ai-output-tests--made)
                    pair)))
               ((symbol-function 'cmacs-ai-session-append-message)
                (lambda (session role text)
                  (push (list session role text)
                        cmacs-ai-output-tests--appended)))
               ((symbol-function 'cmacs-ai-chat-stream)
                (lambda (session prompt callback &optional _executor)
                  (push (cons session prompt) cmacs-ai-output-tests--sent)
                  (funcall callback
                           (list :delta cmacs-ai-output-tests--reply))
                  (funcall callback (list :end :text nil)))))
       ,@body)))

(defun cmacs-ai-output-tests--answered (title &optional session prompt)
  "A finished result buffer called TITLE, with SESSION and PROMPT recorded."
  (let ((buf (cmacs-ai-output-buffer title "subtitle")))
    (when session (cmacs-ai-output-attach-session buf session))
    (cmacs-ai-output-set-request buf
                                 :prompt (or prompt "FIRST-QUESTION")
                                 :provider 'claude :model "sonnet")
    (cmacs-ai-output-append buf "FIRST-ANSWER")
    (cmacs-ai-output-finish buf nil)
    buf))

(defmacro cmacs-ai-output-tests--in (buf &rest body)
  "Run BODY inside result buffer BUF, killing it afterwards."
  (declare (indent 1) (debug t))
  `(let ((b ,buf))
     (unwind-protect (with-current-buffer b ,@body)
       (when (buffer-live-p b) (kill-buffer b)))))

(defun cmacs-ai-output-tests--type (text)
  "Insert TEXT at the end of the compose region."
  (goto-char (point-max))
  (insert text))

;;;; Session lifetime ---------------------------------------------------

(ert-deftest cmacs-ai-output-keeps-the-session-for-a-follow-up ()
  "The session IS the conversation, so freeing it ends any follow-up.

Nothing is re-sent by keeping it -- ai-glib owns the message list in C
-- which is what makes a follow-up cost nothing to set up."
  (cmacs-ai-output-tests--with-stubs
    (let ((pair (cons 'client 'session)))
      (cmacs-ai-output-tests--in (cmacs-ai-output-tests--answered "keep" pair)
        (should cmacs-ai-output--session)
        (should-not cmacs-ai-output-tests--freed)))))

(ert-deftest cmacs-ai-output-frees-the-session-when-follow-ups-are-off ()
  (cmacs-ai-output-tests--with-stubs
    (let ((cmacs-ai-output-followup nil)
          (pair (cons 'client 'session)))
      (cmacs-ai-output-tests--in (cmacs-ai-output-tests--answered "nofu" pair)
        (should-not cmacs-ai-output--session)
        (should (equal (list pair) cmacs-ai-output-tests--freed))
        (should-not cmacs-ai-output--compose-marker)))))

(ert-deftest cmacs-ai-output-frees-the-session-on-a-failed-request ()
  "A failure has nothing to continue, so it holds nothing open."
  (cmacs-ai-output-tests--with-stubs
    (let* ((pair (cons 'client 'session))
           (buf (cmacs-ai-output-buffer "failed")))
      (cmacs-ai-output-attach-session buf pair)
      (cmacs-ai-output-finish buf "no such model")
      (cmacs-ai-output-tests--in buf
        (should-not cmacs-ai-output--session)
        (should-not cmacs-ai-output--compose-marker)
        (should (string-match-p "no such model" (buffer-string)))))))

(ert-deftest cmacs-ai-output-frees-the-session-exactly-once-on-kill ()
  "Quit closes AND frees; the kill hook must not free it a second time."
  (cmacs-ai-output-tests--with-stubs
    (let* ((pair (cons 'client 'session))
           (buf (cmacs-ai-output-tests--answered "once" pair)))
      (with-current-buffer buf (cmacs-ai-output--cancel))
      (kill-buffer buf)
      (should (= 1 (length cmacs-ai-output-tests--freed))))))

(ert-deftest cmacs-ai-output-reset-cancels-the-previous-conversation ()
  "Re-running an action into the same window must not leak the old session."
  (cmacs-ai-output-tests--with-stubs
    (let ((pair (cons 'client 'session)))
      (cmacs-ai-output-tests--answered "reuse" pair)
      (cmacs-ai-output-tests--in (cmacs-ai-output-buffer "reuse" "again")
        (should (equal (list pair) cmacs-ai-output-tests--freed))
        (should-not cmacs-ai-output--compose-marker)
        (should buffer-read-only)))))

;;;; The compose region --------------------------------------------------

(ert-deftest cmacs-ai-output-opens-a-compose-region-when-it-settles ()
  "Not before: there is nothing to follow up on while it is still talking."
  (cmacs-ai-output-tests--with-stubs
    (let ((buf (cmacs-ai-output-buffer "compose")))
      (cmacs-ai-output-attach-session buf (cons 'c 's))
      (cmacs-ai-output-append buf "answer")
      (cmacs-ai-output-tests--in buf
        (should-not cmacs-ai-output--compose-marker)
        (should buffer-read-only)
        (cmacs-ai-output-finish buf nil)
        (should cmacs-ai-output--compose-marker)
        (should-not buffer-read-only)
        (should (string-match-p (regexp-quote
                                 cmacs-ai-output-followup-sentinel)
                                (buffer-string)))))))

(ert-deftest cmacs-ai-output-single-letter-keys-are-typable-in-compose ()
  "`q', `w' and `g' are commands while reading and letters while typing.

A `menu-item' `:filter' is what makes both true at once.  Anything
added to this map that is not a `C-c' key has to do the same, or the
compose region silently stops accepting three letters of the alphabet."
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "keys" (cons 'c 's))
      (goto-char (point-min))
      (should (eq 'cmacs-ai-output-quit (key-binding (kbd "q"))))
      (should (eq 'cmacs-ai-output-copy (key-binding (kbd "w"))))
      (should (eq 'cmacs-ai-output-retry (key-binding (kbd "g"))))
      (goto-char (point-max))
      (dolist (key '("q" "w" "g"))
        (should-not (memq (key-binding (kbd key))
                          '(cmacs-ai-output-quit
                            cmacs-ai-output-copy
                            cmacs-ai-output-retry)))))))

(ert-deftest cmacs-ai-output-control-keys-work-from-anywhere ()
  "Under Evil the bare letters are motions, so these are the real interface."
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "ckeys" (cons 'c 's))
      (dolist (pos (list (point-min) (point-max)))
        (goto-char pos)
        (should (eq 'cmacs-ai-output-send-followup
                    (key-binding (kbd "C-c C-c"))))
        (should (eq 'cmacs-ai-output-quit (key-binding (kbd "C-c C-k"))))
        (should (eq 'cmacs-ai-output-copy (key-binding (kbd "C-c C-w"))))
        (should (eq 'cmacs-ai-output-retry (key-binding (kbd "C-c C-r"))))
        (should (eq 'cmacs-ai-output-promote-to-chat
                    (key-binding (kbd "C-c C-p"))))))))

;;;; The read-only boundary ----------------------------------------------

(ert-deftest cmacs-ai-output-compose-region-is-typable ()
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "typable" (cons 'c 's))
      (cmacs-ai-output-tests--type "a follow-up")
      (should (string-match-p "a follow-up" (buffer-string))))))

(ert-deftest cmacs-ai-output-answer-stays-protected-after-a-failed-edit ()
  "The seal survives being hit, which a `before-change-functions' guard
does not: Emacs clears that hook when a function on it signals, so the
first stray keypress would disarm it and every edit after would land."
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "seal" (cons 'c 's))
      (dolist (_ '(1 2 3))
        (goto-char (point-min))
        (should-error (insert "x") :type 'text-read-only))
      ;; And in the middle of the answer, not just at its edge.
      (goto-char (point-min))
      (should (search-forward "FIRST-ANSWER" nil t))
      (goto-char (match-beginning 0))
      (forward-char 3)
      (should-error (insert "x") :type 'text-read-only)
      ;; The compose region is untouched by all of that.
      (cmacs-ai-output-tests--type "still fine")
      (should (string-match-p "still fine" (buffer-string))))))

(ert-deftest cmacs-ai-output-is-untypable-while-it-streams ()
  (cmacs-ai-output-tests--with-stubs
    (let ((buf (cmacs-ai-output-buffer "streaming")))
      (cmacs-ai-output-append buf "partial")
      (cmacs-ai-output-tests--in buf
        (goto-char (point-max))
        (should-error (insert "x") :type 'buffer-read-only)))))

;;;; Follow-ups ----------------------------------------------------------

(ert-deftest cmacs-ai-output-follow-up-continues-the-same-session ()
  "The point of the whole thing: the model has already seen the answer."
  (cmacs-ai-output-tests--with-stubs
    (let ((pair (cons 'client 'session)))
      (cmacs-ai-output-tests--in
          (cmacs-ai-output-tests--answered "same" pair)
        (cmacs-ai-output-tests--type "now in one sentence")
        (cmacs-ai-output-send-followup)
        (should (= 1 (length cmacs-ai-output-tests--sent)))
        (should (eq (cdr pair) (car (car cmacs-ai-output-tests--sent))))
        (should (equal "now in one sentence"
                       (cdr (car cmacs-ai-output-tests--sent))))
        ;; No new session was made and nothing was replayed.
        (should-not cmacs-ai-output-tests--made)
        (should-not cmacs-ai-output-tests--appended)))))

(ert-deftest cmacs-ai-output-follow-up-renders-both-halves ()
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "render" (cons 'c 's))
      (cmacs-ai-output-tests--type "shorter please")
      (cmacs-ai-output-send-followup)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^\\* you$" text))
        (should (string-match-p "shorter please" text))
        (should (string-match-p "^\\* assistant$" text))
        (should (string-match-p "SECOND-ANSWER" text)))
      ;; And a fresh compose region is waiting, exactly one of them.
      (should cmacs-ai-output--compose-marker)
      (should (= 1 (cl-count-if
                    (lambda (l) (equal l cmacs-ai-output-followup-sentinel))
                    (split-string (buffer-string) "\n")))))))

(ert-deftest cmacs-ai-output-follow-up-empties-the-compose-region ()
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "empty" (cons 'c 's))
      (cmacs-ai-output-tests--type "a question")
      (cmacs-ai-output-send-followup)
      (should (equal "" (string-trim
                         (buffer-substring-no-properties
                          cmacs-ai-output--compose-marker (point-max))))))))

(ert-deftest cmacs-ai-output-refuses-an-empty-follow-up ()
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "blank" (cons 'c 's))
      (should-error (cmacs-ai-output-send-followup) :type 'user-error)
      (should-not cmacs-ai-output-tests--sent))))

(ert-deftest cmacs-ai-output-follow-up-seals-its-own-turn ()
  "Yesterday's answer is as read-only as this morning's."
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "seal2" (cons 'c 's))
      (cmacs-ai-output-tests--type "again")
      (cmacs-ai-output-send-followup)
      (goto-char (point-min))
      (should (search-forward "SECOND-ANSWER" nil t))
      (goto-char (1+ (match-beginning 0)))
      (should-error (insert "x") :type 'text-read-only))))

(ert-deftest cmacs-ai-output-follow-up-tracks-the-conversation ()
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "turns" (cons 'c 's))
      (should (equal '((user . "FIRST-QUESTION") (assistant . "FIRST-ANSWER"))
                     cmacs-ai-output--turns))
      (cmacs-ai-output-tests--type "and again")
      (cmacs-ai-output-send-followup)
      (should (equal '((user . "FIRST-QUESTION")
                       (assistant . "FIRST-ANSWER")
                       (user . "and again")
                       (assistant . "SECOND-ANSWER"))
                     cmacs-ai-output--turns)))))

(ert-deftest cmacs-ai-output-follow-up-opens-a-session-when-there-is-none ()
  "The Tools group renders a return value with no model call at all.

Rather than refuse, open a session and seed it with what is already on
screen, so the model has the context a reader of the window does."
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "lazy" nil)
      (cmacs-ai-output-tests--type "what does that mean?")
      (cmacs-ai-output-send-followup)
      (should (= 1 (length cmacs-ai-output-tests--made)))
      (should (equal '(("user" . "FIRST-QUESTION")
                       ("assistant" . "FIRST-ANSWER"))
                     (mapcar (lambda (a) (cons (nth 1 a) (nth 2 a)))
                             (reverse cmacs-ai-output-tests--appended))))
      (should (eq (cdr (car cmacs-ai-output-tests--made))
                  (car (car cmacs-ai-output-tests--sent)))))))

;;;; Copying -------------------------------------------------------------

(ert-deftest cmacs-ai-output-copy-excludes-header-and-compose ()
  "What `w' yields is the answer, not the furniture around it."
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "copy" (cons 'c 's))
      (cmacs-ai-output-tests--type "DRAFT-NOT-YET-SENT")
      (let ((kill-ring nil))
        (cmacs-ai-output-copy)
        (let ((copied (current-kill 0)))
          (should (string-match-p "FIRST-ANSWER" copied))
          (should-not (string-match-p "#\\+title" copied))
          (should-not (string-match-p "DRAFT-NOT-YET-SENT" copied))
          (should-not (string-match-p
                       (regexp-quote cmacs-ai-output-followup-sentinel)
                       copied)))))))

;;;; Retry vs follow-up --------------------------------------------------

(ert-deftest cmacs-ai-output-retry-is-not-a-follow-up ()
  "`g' asks the original question again; it does not continue anything.

Documented side by side because the difference is invisible from the
window and expensive to discover by accident."
  (cmacs-ai-output-tests--with-stubs
    (let ((runs 0))
      (cmacs-ai-output-tests--in
          (cmacs-ai-output-tests--answered "retry" (cons 'c 's))
        (cmacs-ai-output-set-retry (current-buffer)
                                   (lambda () (setq runs (1+ runs))))
        (cmacs-ai-output-retry)
        (should (= 1 runs))
        (should-not cmacs-ai-output-tests--sent)))))

(ert-deftest cmacs-ai-output-retry-says-so-when-there-is-nothing-to-run ()
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in
        (cmacs-ai-output-tests--answered "noretry" (cons 'c 's))
      (should-error (cmacs-ai-output-retry) :type 'user-error))))


;;;; Promotion ----------------------------------------------------------

;; These need the real chat module AND real session handles: the chat's
;; own setup hands its client to C DEFUNs, which will not take a stand-in
;; symbol.  So only `cmacs-ai-free-session' is intercepted here, and it
;; still frees -- the assertions are about what got freed, not about
;; avoiding the call.

(defmacro cmacs-ai-output-tests--with-real-sessions (&rest body)
  "Run BODY recording every `cmacs-ai-free-session', and still freeing."
  (declare (indent 0) (debug t))
  `(let ((cmacs-ai-output-tests--freed nil)
         (cmacs-ai-output-tests--sent nil)
         (cmacs-ai-output-followup t))
     (cl-letf* ((free (symbol-function 'cmacs-ai-free-session))
                ((symbol-function 'cmacs-ai-free-session)
                 (lambda (pair)
                   (push pair cmacs-ai-output-tests--freed)
                   (funcall free pair)))
                ((symbol-function 'cmacs-ai-chat-stream)
                 (lambda (session prompt callback &optional _executor)
                   (push (cons session prompt) cmacs-ai-output-tests--sent)
                   (funcall callback
                            (list :delta cmacs-ai-output-tests--reply))
                   (funcall callback (list :end :text nil)))))
       ,@body)))

(ert-deftest cmacs-ai-output-promote-hands-the-session-over ()
  "Handed over, not replayed.  `cmacs-ai-chat--rebuild-session' exists
and would re-send the whole conversation to get back where we already
are; the live handle costs nothing and loses nothing."
  (skip-unless (and (fboundp 'cmacs-ai-chat-open)
                    (fboundp 'cmacs-ai-supported-p)
                    (cmacs-ai-supported-p)))
  (cmacs-ai-output-tests--with-real-sessions
    (let* ((pair (cmacs-ai-make-session 'claude nil))
           (buf (cmacs-ai-output-tests--answered "promote" pair))
           chat)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (setq chat (cmacs-ai-output-promote-to-chat)))
            (should (buffer-live-p chat))
            (should-not (buffer-live-p buf))
            (with-current-buffer chat
              (should (derived-mode-p 'cmacs-ai-chat-mode))
              (should (eq pair cmacs-ai-chat-session-pair))
              ;; The prompt this conversation has been held under is the
              ;; action's; the first send must not replace it.
              (should cmacs-ai-chat--system-applied)
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "FIRST-QUESTION" text))
                (should (string-match-p "FIRST-ANSWER" text))))
            ;; The chat made a session on open and never used it.  It is
            ;; freed rather than leaked; ours is not freed at all.
            (should (= 1 (length cmacs-ai-output-tests--freed)))
            (should-not (memq pair cmacs-ai-output-tests--freed)))
        (when (buffer-live-p chat)
          (with-current-buffer chat (setq cmacs-ai-chat-session-pair nil))
          (kill-buffer chat))
        (when (buffer-live-p buf) (kill-buffer buf))
        (ignore-errors (funcall (symbol-function 'cmacs-ai-free-session)
                                pair))))))

(ert-deftest cmacs-ai-output-promote-carries-the-follow-ups-too ()
  (skip-unless (and (fboundp 'cmacs-ai-chat-open)
                    (fboundp 'cmacs-ai-supported-p)
                    (cmacs-ai-supported-p)))
  (cmacs-ai-output-tests--with-real-sessions
    (let* ((pair (cmacs-ai-make-session 'claude nil))
           (buf (cmacs-ai-output-tests--answered "promote2" pair))
           chat)
      (unwind-protect
          (with-current-buffer buf
            (cmacs-ai-output-tests--type "a follow-up question")
            (cmacs-ai-output-send-followup)
            (setq chat (cmacs-ai-output-promote-to-chat))
            (with-current-buffer chat
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "a follow-up question" text))
                (should (string-match-p "SECOND-ANSWER" text)))))
        (when (buffer-live-p chat)
          (with-current-buffer chat (setq cmacs-ai-chat-session-pair nil))
          (kill-buffer chat))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest cmacs-ai-output-promote-refuses-with-nothing-to-promote ()
  (cmacs-ai-output-tests--with-stubs
    (cmacs-ai-output-tests--in (cmacs-ai-output-tests--answered "nada" nil)
      (should-error (cmacs-ai-output-promote-to-chat) :type 'user-error))))

(provide 'cmacs-ai-output-tests)

;;; cmacs-ai-output-tests.el ends here
