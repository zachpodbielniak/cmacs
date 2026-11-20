;;; cmacs-brigade-steer-tests.el --- Steering and usage limits in the brigade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Two things ai-glib 0.13 changed about a brigade run.
;;
;; A message for a RUNNING in-process agent no longer has to wait for
;; its turn to end: the run layer steers the head of the mailbox into
;; the tool loop.  What matters is the mailbox's own rule -- peek, never
;; pop, until the message is known to have landed -- carried over to a
;; three-valued answer:
;;
;;   delivered      remove it
;;   indeterminate  remove it (sent, unconfirmed: queueing it again
;;                  would run it twice)
;;   refused        leave it exactly where it was
;;
;; And a run stopped by a usage or rate limit is parked, not failed:
;; its conversation is kept, it is not restarted before the reset, and
;; mail waiting for it goes out when the limit lifts.
;;
;; No model, no agent process and no new C are needed for any of this:
;; `cmacs-ai-tools-steer' is stubbed (with `&rest', the only arity a stub
;; of a C DEFUN can safely have) and the worker is a mock that records
;; its starts.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-registry nil 'noerror)
(require 'cmacs-brigade-output nil 'noerror)
(require 'cmacs-brigade-log nil 'noerror)
(require 'cmacs-brigade-mailbox nil 'noerror)
(require 'cmacs-brigade-run nil 'noerror)
(require 'cmacs-brigade-agent-def nil 'noerror)
(require 'cl-lib)
(require 'subr-x)

(defvar cmacs-brigade-output-dir)
(defvar cmacs-brigade-mailbox-dir)
(defvar cmacs-brigade--mailbox)
(defvar cmacs-brigade--conversations)
(defvar cmacs-brigade--runs)
(defvar cmacs-brigade--finishing)
(defvar cmacs-brigade--steering)
(defvar cmacs-brigade-steer-running)
(defvar cmacs-brigade-run-finished-functions)
(defvar cmacs-brigade-turn-finished-functions)
(defvar cmacs-brigade-mailbox-delivered-functions)

;; `fboundp' on what the tests call, never `cmacs-feature-p' -- which is
;; void when this file runs on its own and would skip everything green.
(defun cmacs-brigade-steer-tests--available-p ()
  (and (featurep 'cmacs-brigade-run)
       (featurep 'cmacs-brigade-mailbox)
       (fboundp 'cmacs-brigade--on-steered)
       (fboundp 'cmacs-brigade--park-limited)
       (fboundp 'cmacs-brigade-task-adopt)))

(defvar cmacs-brigade-steer-tests--starts nil
  "Prompts the mock worker was started with, newest first.")

(defvar cmacs-brigade-steer-tests--steers nil
  "Calls the stubbed `cmacs-ai-tools-steer' saw, newest first.
Each is (EXECUTOR TEXT CALLBACK).")

(defun cmacs-brigade-steer-tests--install-mocks ()
  "Register the mock worker and agent."
  (cmacs-brigade-register-worker
   :name 'steer-mock
   :description "Record the start and do nothing."
   :supports-session t
   :start (lambda (_task-id _agent prompt _cwd _env _endpoint)
            (push prompt cmacs-brigade-steer-tests--starts)
            ;; Shaped like the in-process worker's run: an executor
            ;; handle, which is what a steer is sent to.
            (list :session '(1 . 2) :executor 42))
   :cancel #'ignore)
  (cmacs-brigade-register-agent
   :name 'steer-mock-agent :prompt "You are a test."
   :worker 'steer-mock :tools '(*)))

(defmacro cmacs-brigade-steer-tests--with-env (&rest body)
  "Run BODY with throwaway state, the mocks, and a stubbed steer."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "brigade-steer" t))
          (cmacs-brigade-output-dir (expand-file-name "out" dir))
          (cmacs-brigade-mailbox-dir (expand-file-name "mbx" dir))
          (cmacs-brigade-steer-tests--starts nil)
          (cmacs-brigade-steer-tests--steers nil)
          (cmacs-brigade-steer-running t)
          (cmacs-brigade-run-finished-functions nil)
          (cmacs-brigade-turn-finished-functions nil)
          (cmacs-brigade-mailbox-delivered-functions nil))
     (cmacs-brigade-steer-tests--install-mocks)
     (dolist (h (list cmacs-brigade--mailbox cmacs-brigade--conversations
                      cmacs-brigade--runs cmacs-brigade--finishing
                      cmacs-brigade--steering))
       (clrhash h))
     (cl-letf (((symbol-function 'cmacs-ai-tools-steer)
                (lambda (&rest args)
                  (push args cmacs-brigade-steer-tests--steers)
                  (length cmacs-brigade-steer-tests--steers))))
       (unwind-protect (progn ,@body)
         ;; Timers first: a parked conversation holds one, and a timer
         ;; firing into the next test's tables would be a mystery.
         (maphash (lambda (_id c)
                    (when-let* ((timer (plist-get c :limit-timer)))
                      (when (timerp timer) (cancel-timer timer))))
                  cmacs-brigade--conversations)
         (dolist (h (list cmacs-brigade--mailbox cmacs-brigade--conversations
                          cmacs-brigade--runs cmacs-brigade--finishing
                          cmacs-brigade--steering))
           (clrhash h))
         (dolist (r (cmacs-brigade-task-list))
           (when (string-prefix-p "steer-test" (plist-get r :id))
             (cmacs-brigade-task-forget (plist-get r :id))))
         (delete-directory dir t)))))

(defmacro cmacs-brigade-steer-tests--with-running-task (id-var &rest body)
  "Run BODY with a mock task bound to ID-VAR, its first turn in flight.
The worker pretends to be `inproc': steering is offered to that worker
only, because it is the only one whose loop has a seam."
  (declare (indent 1))
  `(cmacs-brigade-steer-tests--with-env
     (let ((,id-var "steer-test-task"))
       (cmacs-brigade-task-adopt ,id-var "mock.org" "steer-mock-agent" "t")
       (cmacs-brigade-task-transition ,id-var 'queued)
       (should (cmacs-brigade-start-task ,id-var))
       (should (eq 'running
                   (plist-get (cmacs-brigade-task-get ,id-var) :state)))
       (puthash ,id-var
                (plist-put (gethash ,id-var cmacs-brigade--runs)
                           :worker 'inproc)
                cmacs-brigade--runs)
       ,@body)))

(defun cmacs-brigade-steer-tests--texts (id)
  "The texts waiting in task ID's mailbox, oldest first."
  (mapcar (lambda (m) (plist-get m :text)) (cmacs-brigade-mailbox-list id)))

(defun cmacs-brigade-steer-tests--answer (result &optional reason)
  "Answer the most recent stubbed steer with RESULT and REASON."
  (let ((call (car cmacs-brigade-steer-tests--steers)))
    (funcall (nth 2 call) (list :steer result reason 1))))

;;;; Steering a running turn ---------------------------------------------

(ert-deftest cmacs-brigade-steer-running-turn-is-steered ()
  "A message for a running in-process agent goes to its executor now,
and stays in the mailbox until the answer comes back."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade-mailbox-send id "use the staging db" "human")
    (should (= 1 (length cmacs-brigade-steer-tests--steers)))
    (let ((call (car cmacs-brigade-steer-tests--steers)))
      (should (eql 42 (nth 0 call)))
      (should (equal "use the staging db" (nth 1 call)))
      (should (functionp (nth 2 call))))
    ;; Peeked, not popped: nothing is known to have landed yet.
    (should (equal '("use the staging db")
                   (cmacs-brigade-steer-tests--texts id)))
    (should (gethash id cmacs-brigade--steering))
    ;; No second turn was started for it.
    (should (= 1 (length cmacs-brigade-steer-tests--starts)))))

(ert-deftest cmacs-brigade-steer-delivered-drops-the-message ()
  "`delivered': the running turn has the words, so the mailbox must not."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (let ((delivered nil))
      (add-hook 'cmacs-brigade-mailbox-delivered-functions
                (lambda (task msg) (push (cons task (plist-get msg :text))
                                         delivered)))
      (cmacs-brigade-mailbox-send id "one" "human")
      (cmacs-brigade-steer-tests--answer 'delivered)
      (should-not (cmacs-brigade-mailbox-list id))
      (should-not (gethash id cmacs-brigade--steering))
      ;; Observers of delivery hear about it exactly as for a pop.
      (should (equal delivered (list (cons id "one")))))))

(ert-deftest cmacs-brigade-steer-indeterminate-drops-the-message ()
  "`indeterminate' is sent-but-unconfirmed and counts as delivered.
Leaving it queued would start a turn with words that may already be
running -- the one mistake steering must never make."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade-mailbox-send id "one" "human")
    (cmacs-brigade-steer-tests--answer 'indeterminate "the run ended")
    (should-not (cmacs-brigade-mailbox-list id))
    (should-not (gethash id cmacs-brigade--steering))))

(ert-deftest cmacs-brigade-steer-refused-leaves-the-message ()
  "`refused' is provably not delivered: the message stays at the head,
and is not offered again while the same turn is still running."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade-mailbox-send id "one" "human")
    (cmacs-brigade-steer-tests--answer 'refused "not steerable now")
    (should (equal '("one") (cmacs-brigade-steer-tests--texts id)))
    (should-not (gethash id cmacs-brigade--steering))
    ;; A refusal is not retried in a loop.
    (should (= 1 (length cmacs-brigade-steer-tests--steers)))
    ;; When the turn ends, the message becomes the next turn, as it
    ;; always did.
    (cmacs-brigade--finish id 'done "first answer")
    (should (equal "one" (car cmacs-brigade-steer-tests--starts)))
    (should-not (cmacs-brigade-mailbox-list id))))

(ert-deftest cmacs-brigade-steer-one-at-a-time-in-order ()
  "Only the head is offered, and the next only once the first is settled."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade-mailbox-send id "one" "human")
    (cmacs-brigade-mailbox-send id "two" "human")
    (should (= 1 (length cmacs-brigade-steer-tests--steers)))
    (should (equal "one" (nth 1 (car cmacs-brigade-steer-tests--steers))))
    (cmacs-brigade-steer-tests--answer 'delivered)
    ;; The answer's own kick offers the second.
    (should (= 2 (length cmacs-brigade-steer-tests--steers)))
    (should (equal "two" (nth 1 (car cmacs-brigade-steer-tests--steers))))
    (should (equal '("two") (cmacs-brigade-steer-tests--texts id)))))

(ert-deftest cmacs-brigade-steer-in-flight-blocks-the-next-turn ()
  "A turn that ends while a steer is unanswered must not start the next
turn with the same message; the steer's answer decides."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade-mailbox-send id "one" "human")
    (cmacs-brigade--finish id 'done "first answer")
    ;; Still exactly the opening turn: the message is spoken for.
    (should (= 1 (length cmacs-brigade-steer-tests--starts)))
    (should (equal '("one") (cmacs-brigade-steer-tests--texts id)))
    ;; Refused (the turn ended first): now it becomes the next turn.
    (cmacs-brigade-steer-tests--answer 'refused "no active turn")
    (should (equal "one" (car cmacs-brigade-steer-tests--starts)))
    (should (= 2 (length cmacs-brigade-steer-tests--starts)))))

(ert-deftest cmacs-brigade-steer-in-flight-delivered-after-the-turn ()
  "...and if that late answer is `delivered', no turn is started for it."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade-mailbox-send id "one" "human")
    (cmacs-brigade--finish id 'done "first answer")
    (cmacs-brigade-steer-tests--answer 'delivered)
    (should (= 1 (length cmacs-brigade-steer-tests--starts)))
    (should-not (cmacs-brigade-mailbox-list id))))

(ert-deftest cmacs-brigade-steer-removes-by-identity ()
  "The message is removed by identity, not by position: something else
may have reordered the queue while the steer was in flight."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade-mailbox-send id "one" "human")
    (cmacs-brigade-mailbox-enqueue id "two" "human")
    ;; `agent_drop' takes the steered message out from under the steer.
    (cmacs-brigade-mailbox-drop id 0)
    (cmacs-brigade-steer-tests--answer 'delivered)
    ;; "two" was never delivered and must still be there.
    (should (member "two" (cmacs-brigade-steer-tests--texts id)))))

(ert-deftest cmacs-brigade-steer-only-the-inproc-worker ()
  "A subprocess worker has no seam: its message waits for the turn."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (puthash id (plist-put (gethash id cmacs-brigade--runs)
                           :worker 'claude-code)
             cmacs-brigade--runs)
    (cmacs-brigade-mailbox-send id "one" "human")
    (should-not cmacs-brigade-steer-tests--steers)
    (should (equal '("one") (cmacs-brigade-steer-tests--texts id)))))

(ert-deftest cmacs-brigade-steer-can-be-turned-off ()
  "`cmacs-brigade-steer-running' nil restores wait-for-the-next-turn."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (let ((cmacs-brigade-steer-running nil))
      (cmacs-brigade-mailbox-send id "one" "human")
      (should-not cmacs-brigade-steer-tests--steers))))

;;;; Usage limits ----------------------------------------------------------

(ert-deftest cmacs-brigade-limit-parks-instead-of-failing ()
  "A session limit parks the task with its conversation intact, and the
reason says when the limit lifts."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (let ((ended nil) (turns nil)
          (reset (+ (floor (float-time)) 3600)))
      (add-hook 'cmacs-brigade-run-finished-functions
                (lambda (&rest args) (push args ended)))
      (add-hook 'cmacs-brigade-turn-finished-functions
                (lambda (&rest args) (push args turns)))
      (cmacs-brigade--inproc-done
       id (list :error "claude: Max plan" :kind 'session-limit :reset reset))
      (let ((rec (cmacs-brigade-task-get id)))
        (should (eq 'waiting-input (plist-get rec :state))))
      ;; Kept: the session, and for an isolated agent its worktree.
      (should (cmacs-brigade-conversation-p id))
      (should (cmacs-brigade--limited-p id))
      (should (timerp (plist-get (cmacs-brigade-conversation-get id)
                                 :limit-timer)))
      ;; A turn ended; the run did not.  The notifier listens on the
      ;; second and would announce a failure.
      (should (= 1 (length turns)))
      (should-not ended)
      ;; The slot is released all the same.
      (should-not (gethash id cmacs-brigade--runs)))))

(ert-deftest cmacs-brigade-limit-is-not-retried-before-the-reset ()
  "Mail sent to a parked task waits for the reset, then goes out."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade--inproc-done
     id (list :error "slow down" :kind 'rate-limited
              :reset (+ (floor (float-time)) 3600)))
    (cmacs-brigade-mailbox-send id "carry on" "human")
    ;; Not started: it would be refused at once and park again.
    (should (= 1 (length cmacs-brigade-steer-tests--starts)))
    (should (equal '("carry on") (cmacs-brigade-steer-tests--texts id)))
    ;; The reset arrives.
    (cmacs-brigade--limit-lifted id)
    (should-not (cmacs-brigade--limited-p id))
    (should (equal "carry on" (car cmacs-brigade-steer-tests--starts)))
    (should (= 2 (length cmacs-brigade-steer-tests--starts)))))

(ert-deftest cmacs-brigade-limit-with-no-reset-still-waits ()
  "No stated reset is not \"retry now\": the fallback delay applies."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade--inproc-done
     id (list :error "limit" :kind 'session-limit :reset nil))
    (should (cmacs-brigade--limited-p id))
    (should (> (plist-get (cmacs-brigade-conversation-get id) :limit-until)
               (float-time)))))

(ert-deftest cmacs-brigade-limit-ordinary-errors-still-fail ()
  "Every other error ends the run `failed', as before -- including a
lapsed login and an empty balance, which waiting does not fix."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (dolist (payload (list (list :error "boom")
                         (list :error "sign in" :kind 'signed-out :reset nil)
                         (list :error "no credit" :kind 'quota :reset nil)))
    (cmacs-brigade-steer-tests--with-running-task id
      (cmacs-brigade--inproc-done id payload)
      (should (eq 'failed (plist-get (cmacs-brigade-task-get id) :state)))
      (should-not (cmacs-brigade-conversation-p id)))))

(ert-deftest cmacs-brigade-limit-success-is-unchanged ()
  "A turn that answered is `done'; the extension changes nothing for it."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade--inproc-done id (list :text "all good"))
    (should (eq 'done (plist-get (cmacs-brigade-task-get id) :state)))
    (should (cmacs-brigade-conversation-p id))
    (should-not (cmacs-brigade--limited-p id))))

(ert-deftest cmacs-brigade-limit-timer-dies-with-the-conversation ()
  "Closing a parked conversation cancels the timer waiting to kick it."
  (skip-unless (cmacs-brigade-steer-tests--available-p))
  (cmacs-brigade-steer-tests--with-running-task id
    (cmacs-brigade--inproc-done
     id (list :error "limit" :kind 'session-limit
              :reset (+ (floor (float-time)) 3600)))
    (let ((timer (plist-get (cmacs-brigade-conversation-get id)
                            :limit-timer)))
      (should (memq timer timer-list))
      (cmacs-brigade-close-conversation id)
      (should-not (memq timer timer-list)))))

(ert-deftest cmacs-brigade-acp-has-no-subprocess-worker ()
  "An ACP provider runs in-process: ai-glib speaks the protocol, and
there is no `PROGRAM < prompt' form for a worker to launch."
  (skip-unless (featurep 'cmacs-brigade-run))
  (should-not (assq 'acp cmacs-brigade-cli-providers))
  (let ((cmacs-brigade-worker 'inproc))
    (should (eq 'inproc
                (cmacs-brigade-resolve-worker '(:model "acp/default"))))))

(provide 'cmacs-brigade-steer-tests)

;;; cmacs-brigade-steer-tests.el ends here
