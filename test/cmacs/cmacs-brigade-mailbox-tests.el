;;; cmacs-brigade-mailbox-tests.el --- Mailboxes and conversations  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The mailbox turns a task from something that runs once into something
;; you can go on talking to, and almost everything that can go wrong with
;; it is a lifecycle problem rather than a data-structure one: a message
;; delivered into the gap between a turn ending and the task parking, a
;; sandbox rebuilt between turns and losing the agent's work, a parked
;; conversation that cannot be cancelled, totals that reset every turn.
;;
;; So most of this file drives a real task through a mock worker rather
;; than testing the queue in isolation.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-registry nil 'noerror)
(require 'cmacs-brigade-output nil 'noerror)
(require 'cmacs-brigade-log nil 'noerror)
(require 'cmacs-brigade-mailbox nil 'noerror)
(require 'cmacs-brigade-run nil 'noerror)
(require 'cmacs-brigade-agent-def nil 'noerror)
(require 'cl-lib)
(require 'subr-x)

;; `fboundp', not `cmacs-feature-p': the latter is void when this file is
;; run on its own, which would make every test skip and the suite report
;; green without executing anything.
(defun cmacs-brigade-mailbox-tests--available-p ()
  (and (featurep 'cmacs-brigade-mailbox)
       (fboundp 'cmacs-brigade-mailbox-send)))

(defun cmacs-brigade-mailbox-tests--runnable-p ()
  (and (cmacs-brigade-mailbox-tests--available-p)
       (featurep 'cmacs-brigade-run)
       (fboundp 'cmacs-brigade-task-adopt)))

(defvar cmacs-brigade-mailbox-tests--starts nil
  "Every call the mock worker saw, newest first.")

(defvar cmacs-brigade-mailbox-tests--fail-start nil
  "When non-nil, the mock worker signals instead of starting.")

(defvar cmacs-brigade-mailbox-tests--prepares 0
  "How many times the mock isolation backend prepared.")

(defun cmacs-brigade-mailbox-tests--install-mocks ()
  "Register the mock worker, isolation and agent used by these tests."
  (cmacs-brigade-register-worker
   :name 'mock
   :description "Record the call and do nothing."
   :supports-session t
   :start (lambda (task-id _agent prompt cwd _env _endpoint)
            (when cmacs-brigade-mailbox-tests--fail-start
              (error "mock worker refuses to start"))
            (push (list :task task-id :prompt prompt :cwd cwd)
                  cmacs-brigade-mailbox-tests--starts)
            (list :mock t))
   :cancel #'ignore)
  (cmacs-brigade-register-worker
   :name 'mock-no-session
   :description "A worker that cannot continue a conversation."
   :supports-session nil
   :start (lambda (task-id _agent prompt _cwd _env _endpoint)
            (push (list :task task-id :prompt prompt)
                  cmacs-brigade-mailbox-tests--starts)
            (list :mock t))
   :cancel #'ignore)
  (cmacs-brigade-register-isolation
   :name 'mock-iso
   :prepare (lambda (_id)
              (setq cmacs-brigade-mailbox-tests--prepares
                    (1+ cmacs-brigade-mailbox-tests--prepares))
              (list :cwd "/tmp/mock-iso/" :env nil))
   :teardown #'ignore
   :describe (lambda () "mock"))
  (cmacs-brigade-register-agent
   :name 'mock-agent :prompt "You are a test." :worker 'mock :tools '(*))
  (cmacs-brigade-register-agent
   :name 'mock-agent-iso :prompt "You are a test."
   :worker 'mock :isolation 'mock-iso :tools '(*))
  (cmacs-brigade-register-agent
   :name 'mock-agent-noses :prompt "You are a test."
   :worker 'mock-no-session :tools '(*)))

(defmacro cmacs-brigade-mailbox-tests--with-task (id-var &rest body)
  "Run BODY with a started, parked mock task bound to ID-VAR.

Leaves the task in `waiting-input' with a live conversation -- the state
a real agent is in between messages, and the starting point for almost
every question worth asking here."
  (declare (indent 1))
  `(cmacs-brigade-mailbox-tests--with-env
     (let ((,id-var "mbx-test-task"))
       (cmacs-brigade-task-adopt ,id-var "mock.org" "mock-agent" "t")
       (cmacs-brigade-task-transition ,id-var 'queued)
       (should (cmacs-brigade-start-task ,id-var))
       (cmacs-brigade--finish ,id-var 'done "first answer")
       (should (eq 'done (plist-get (cmacs-brigade-task-get ,id-var) :state)))
       (should (cmacs-brigade-conversation-p ,id-var))
       ,@body)))

(defmacro cmacs-brigade-mailbox-tests--with-env (&rest body)
  "Run BODY with throwaway state directories and the mocks installed."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "brigade-mbx" t))
          (cmacs-brigade-output-dir (expand-file-name "out" dir))
          (cmacs-brigade-mailbox-dir (expand-file-name "mbx" dir))
          (cmacs-brigade-mailbox-tests--starts nil)
          (cmacs-brigade-mailbox-tests--fail-start nil)
          (cmacs-brigade-mailbox-tests--prepares 0)
          (cmacs-brigade-run-finished-functions nil)
          (cmacs-brigade-turn-finished-functions nil))
     (cmacs-brigade-mailbox-tests--install-mocks)
     (clrhash cmacs-brigade--mailbox)
     (clrhash cmacs-brigade--conversations)
     (clrhash cmacs-brigade--runs)
     (clrhash cmacs-brigade--finishing)
     (unwind-protect (progn ,@body)
       (clrhash cmacs-brigade--mailbox)
       (clrhash cmacs-brigade--conversations)
       (clrhash cmacs-brigade--runs)
       (clrhash cmacs-brigade--finishing)
       (dolist (r (cmacs-brigade-task-list))
         (when (string-prefix-p "mbx-test" (plist-get r :id))
           (cmacs-brigade-task-forget (plist-get r :id))))
       (delete-directory dir t))))


;;;; The queue itself

(ert-deftest cmacs-brigade-mailbox-is-fifo ()
  "Messages come out in the order they went in."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (cmacs-brigade-mailbox-tests--with-env
    (dolist (m '("one" "two" "three"))
      (cmacs-brigade-mailbox-enqueue "T" m "human"))
    (should (equal '("one" "two" "three")
                   (mapcar (lambda (m) (plist-get m :text))
                           (cmacs-brigade-mailbox-list "T"))))
    (should (equal "one" (plist-get (cmacs-brigade-mailbox-peek "T") :text)))
    (should (equal "one" (plist-get (cmacs-brigade-mailbox-pop "T") :text)))
    (should (equal "two" (plist-get (cmacs-brigade-mailbox-peek "T") :text)))))

(ert-deftest cmacs-brigade-mailbox-peek-does-not-consume ()
  "Peeking twice returns the same message.

This is what protects a message from a start that fails: the run layer
peeks, tries to start, and only pops once the turn is really under way."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (cmacs-brigade-mailbox-tests--with-env
    (cmacs-brigade-mailbox-enqueue "T" "only" "human")
    (should (cmacs-brigade-mailbox-peek "T"))
    (should (cmacs-brigade-mailbox-peek "T"))
    (should (= 1 (cmacs-brigade-mailbox-count "T")))))

(ert-deftest cmacs-brigade-mailbox-drop-by-index-and-whole ()
  "Dropping removes exactly one, or all, and rejects a bad index."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (cmacs-brigade-mailbox-tests--with-env
    (dolist (m '("a" "b" "c")) (cmacs-brigade-mailbox-enqueue "T" m))
    (should (= 1 (cmacs-brigade-mailbox-drop "T" 1)))
    (should (equal '("a" "c") (mapcar (lambda (m) (plist-get m :text))
                                      (cmacs-brigade-mailbox-list "T"))))
    (should-error (cmacs-brigade-mailbox-drop "T" 9))
    (should-error (cmacs-brigade-mailbox-drop "T" -1))
    (should (= 2 (cmacs-brigade-mailbox-drop "T")))
    (should (= 0 (cmacs-brigade-mailbox-count "T")))))

(ert-deftest cmacs-brigade-mailbox-is-bounded ()
  "A runaway sender is refused rather than allowed to queue forever."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((cmacs-brigade-mailbox-max 3))
      (dotimes (i 3) (cmacs-brigade-mailbox-enqueue "T" (format "%d" i)))
      (should-error (cmacs-brigade-mailbox-enqueue "T" "one too many")))))

(ert-deftest cmacs-brigade-mailbox-survives-a-restart ()
  "A queued message outlives the process that took it.

The whole point of queueing against a busy agent is that you can walk
away; losing it on the restart that happens while you are gone would
make the queue pointless in exactly the case it exists for."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (cmacs-brigade-mailbox-tests--with-env
    (cmacs-brigade-mailbox-enqueue "T" "remember me" "human")
    (clrhash cmacs-brigade--mailbox)
    (should (= 0 (cmacs-brigade-mailbox-count "T")))
    (cmacs-brigade-mailbox-restore)
    (should (equal "remember me"
                   (plist-get (cmacs-brigade-mailbox-peek "T") :text)))))

(ert-deftest cmacs-brigade-mailbox-restore-skips-corrupt-lines ()
  "A damaged mailbox file loses that line, not the mailbox."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (cmacs-brigade-mailbox-tests--with-env
    (cmacs-brigade-mailbox-enqueue "T" "good" "human")
    (write-region "{\"text\":\"trunc\n" nil
                  (cmacs-brigade-mailbox-file "T") 'append 'silent)
    (clrhash cmacs-brigade--mailbox)
    (cmacs-brigade-mailbox-restore)
    (should (= 1 (cmacs-brigade-mailbox-count "T")))))

(ert-deftest cmacs-brigade-mailbox-empty-queue-removes-its-file ()
  "Draining a mailbox does not leave an empty file behind to restore."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (cmacs-brigade-mailbox-tests--with-env
    (cmacs-brigade-mailbox-enqueue "T" "x")
    (should (file-exists-p (cmacs-brigade-mailbox-file "T")))
    (cmacs-brigade-mailbox-pop "T")
    (should-not (file-exists-p (cmacs-brigade-mailbox-file "T")))))


;;;; Sending

(ert-deftest cmacs-brigade-mailbox-send-rejects-unknown-task ()
  "Sending to a task that does not exist is an error, not a silent queue."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (should-error (cmacs-brigade-mailbox-send "nope" "hi"))))

(ert-deftest cmacs-brigade-mailbox-send-refuses-a-sessionless-worker ()
  "A worker that cannot continue a conversation says so.

Re-running bash with a follow-up message produces a process that has
never seen the first one.  Presenting that as a continuation would be a
lie the caller has no way to detect, so it is refused outright."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (cmacs-brigade-task-adopt "mbx-test-ns" "mock.org" "mock-agent-noses" "t")
    (should-error (cmacs-brigade-mailbox-send "mbx-test-ns" "more please"))
    (should (= 0 (cmacs-brigade-mailbox-count "mbx-test-ns")))))

(ert-deftest cmacs-brigade-mailbox-send-logs-the-message ()
  "What you said is in the log before the agent has seen it."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-send id "second question" "human")
    (should (cl-find-if (lambda (e)
                          (and (equal "message" (alist-get 'kind e))
                               (equal "second question" (alist-get 'text e))))
                        (cmacs-brigade-log-read id)))))


;;;; The conversation lifecycle

(ert-deftest cmacs-brigade-conversation-finishes-but-stays-resumable ()
  "A task that answered is `done', and still has a conversation.

`done' is what every existing observer means by finished, so a task that
sat in some open state after answering would tell the dashboard, the
notifier and the plan that it was still going.  What makes it resumable
is the conversation record outliving the turn, not the task's state."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (should (eq 'done (plist-get (cmacs-brigade-task-get id) :state)))
    (should (cmacs-brigade-conversation-p id))
    (should (= 1 (cmacs-brigade-conversation-turn id)))))

(ert-deftest cmacs-brigade-conversation-released-when-a-turn-fails ()
  "A turn that ended badly releases the conversation.

Silently resuming a session whose last turn broke is the kind of
recovery that should be asked for rather than assumed."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((id "mbx-test-boom"))
      (cmacs-brigade-task-adopt id "mock.org" "mock-agent" "t")
      (cmacs-brigade-task-transition id 'queued)
      (should (cmacs-brigade-start-task id))
      (cmacs-brigade--finish id 'failed "it broke" "boom")
      (should (eq 'failed (plist-get (cmacs-brigade-task-get id) :state)))
      (should-not (cmacs-brigade-conversation-p id)))))

(ert-deftest cmacs-brigade-run-finished-still-fires-per-turn ()
  "`run-finished-functions' keeps its old contract exactly.

Every observer that predates conversations -- output, notification, the
plan -- is wired to this hook, and a task answering without firing it
would look to all of them as though it had never finished."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((seen nil)
          (id "mbx-test-hook"))
      (add-hook 'cmacs-brigade-run-finished-functions
                (lambda (task state output) (push (list task state output) seen)))
      (cmacs-brigade-task-adopt id "mock.org" "mock-agent" "t")
      (cmacs-brigade-task-transition id 'queued)
      (should (cmacs-brigade-start-task id))
      (cmacs-brigade--finish id 'done "one")
      (should (equal (list id 'done "one") (car seen)))
      (cmacs-brigade-mailbox-send id "two" "human")
      (cmacs-brigade--finish id 'done "two")
      (should (equal (list id 'done "two") (car seen)))
      (should (= 2 (length seen))))))

(ert-deftest cmacs-brigade-conversation-resumes-with-the-message-alone ()
  "A resumed turn's prompt is the message and nothing else.

Not the plan's task text, and not the agent's standing instructions: the
session already has those, and re-sending them would replay the whole
system prompt into the middle of a conversation."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-send id "the follow-up" "human")
    (should (eq 'running (plist-get (cmacs-brigade-task-get id) :state)))
    (let ((last (car cmacs-brigade-mailbox-tests--starts)))
      (should (equal id (plist-get last :task)))
      (should (equal "the follow-up" (plist-get last :prompt)))
      (should-not (string-match-p "You are a test"
                                  (plist-get last :prompt))))
    ;; And it was consumed, so the next turn does not repeat it.
    (should (= 0 (cmacs-brigade-mailbox-count id)))))

(ert-deftest cmacs-brigade-conversation-turn-counts-up ()
  "Each answered message is a new turn."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-send id "two" "human")
    (cmacs-brigade--finish id 'done "second answer")
    (should (= 2 (cmacs-brigade-conversation-turn id)))
    (cmacs-brigade-mailbox-send id "three" "human")
    (cmacs-brigade--finish id 'done "third answer")
    (should (= 3 (cmacs-brigade-conversation-turn id)))))

(ert-deftest cmacs-brigade-conversation-keeps-every-turns-output ()
  "Turn N's reply is still readable after turn N+1 has finished.

A parent that polls may not have collected turn N yet when turn N+1
lands, and overwriting the single output file destroyed it."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-send id "two" "human")
    (cmacs-brigade--finish id 'done "second answer")
    (should (equal "first answer" (cmacs-brigade-output-get id 1)))
    (should (equal "second answer" (cmacs-brigade-output-get id 2)))
    (should (equal "second answer" (cmacs-brigade-output-get id)))))

(ert-deftest cmacs-brigade-conversation-reuses-parked-isolation ()
  "Isolation is prepared once and reused, not rebuilt every turn.

Rebuilding it would delete the agent's uncommitted work while its
conversation still believes it made those edits -- after which the model
builds confidently on files that no longer exist."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((id "mbx-test-iso"))
      (cmacs-brigade-task-adopt id "mock.org" "mock-agent-iso" "t")
      (cmacs-brigade-task-transition id 'queued)
      (should (cmacs-brigade-start-task id))
      (cmacs-brigade--finish id 'done "one")
      (cmacs-brigade-mailbox-send id "two" "human")
      (cmacs-brigade--finish id 'done "two")
      (cmacs-brigade-mailbox-send id "three" "human")
      (cmacs-brigade--finish id 'done "three")
      (should (= 3 (cmacs-brigade-conversation-turn id)))
      (should (= 1 cmacs-brigade-mailbox-tests--prepares))
      ;; And every turn ran in the same directory.
      (should (cl-every (lambda (s) (equal "/tmp/mock-iso/" (plist-get s :cwd)))
                        cmacs-brigade-mailbox-tests--starts)))))

(ert-deftest cmacs-brigade-conversation-cwd-does-not-drift ()
  "A resumed turn runs where the first one did.

For a CLI worker this is not merely tidy: claude resolves `--resume'
against the project directory, so a drifted cwd silently starts a fresh
conversation rather than failing."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (let ((first-cwd (plist-get (car cmacs-brigade-mailbox-tests--starts) :cwd)))
      ;; Move the editor somewhere else entirely, as a sentinel firing in
      ;; an unrelated buffer would.
      (let ((default-directory "/usr/"))
        (cmacs-brigade-mailbox-send id "two" "human"))
      (should (equal first-cwd
                     (plist-get (car cmacs-brigade-mailbox-tests--starts)
                                :cwd))))))


;;;; The delivery race

(ert-deftest cmacs-brigade-mailbox-send-during-finish-is-not-lost ()
  "A message arriving while a turn is being retired still gets delivered.

Brigade tool calls over MCP are evaluated from inside Emacs's pselect
hook and the finished hooks pump, so a send genuinely can run in the
middle of a completion.  The sender's kick is refused by the in-progress
flag; the re-read after the hooks is what catches it."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (let ((sent nil))
      (add-hook 'cmacs-brigade-turn-finished-functions
                (lambda (task _turn _output)
                  (unless sent
                    (setq sent t)
                    ;; Exactly the interleaving the guard exists for.
                    (cmacs-brigade-mailbox-send task "from inside" "human"))))
      (cmacs-brigade-mailbox-send id "kick it off" "human")
      (cmacs-brigade--finish id 'done "answer to the first")
      ;; The message sent from inside the hook was picked up: the task is
      ;; running again with it, rather than parked with it stranded.
      (should (eq 'running (plist-get (cmacs-brigade-task-get id) :state)))
      (should (equal "from inside"
                     (plist-get (car cmacs-brigade-mailbox-tests--starts)
                                :prompt))))))

(ert-deftest cmacs-brigade-finish-is-not-re-entrant ()
  "A second finish for the same turn does nothing.

A cancel racing a completing worker used to fire the turn hooks twice,
which delivers the same reply to the caller twice."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (let ((turns 0))
      (add-hook 'cmacs-brigade-turn-finished-functions
                (lambda (_task _turn _output)
                  (setq turns (1+ turns))
                  ;; Re-enter from inside, which is how it really happens.
                  (cmacs-brigade--finish id 'done "again")))
      (cmacs-brigade-mailbox-send id "go" "human")
      (cmacs-brigade--finish id 'done "answer")
      (should (= 1 turns)))))

(ert-deftest cmacs-brigade-failed-start-keeps-the-message ()
  "A turn that cannot start leaves its message at the head of the queue.

Popping at delivery time meant a start failure silently ate what
somebody had typed."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (setq cmacs-brigade-mailbox-tests--fail-start t)
    (cmacs-brigade-mailbox-send id "please survive" "human")
    (should (= 1 (cmacs-brigade-mailbox-count id)))
    (should (equal "please survive"
                   (plist-get (cmacs-brigade-mailbox-peek id) :text)))
    ;; Parked rather than failed, so the next attempt can try.
    (should (eq 'waiting-input (plist-get (cmacs-brigade-task-get id) :state)))
    ;; And when the obstacle clears, it goes through.
    (setq cmacs-brigade-mailbox-tests--fail-start nil)
    (cmacs-brigade-kick-conversation id)
    (should (eq 'running (plist-get (cmacs-brigade-task-get id) :state)))
    (should (= 0 (cmacs-brigade-mailbox-count id)))))

(ert-deftest cmacs-brigade-resume-gives-up-after-repeated-failures ()
  "A conversation that can never restart fails loudly instead of looping."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (let ((cmacs-brigade-conversation-max-attempts 2))
      (setq cmacs-brigade-mailbox-tests--fail-start t)
      (cmacs-brigade-mailbox-send id "doomed" "human")
      (cmacs-brigade-kick-conversation id)
      (should (eq 'failed (plist-get (cmacs-brigade-task-get id) :state)))
      (should-not (cmacs-brigade-conversation-p id)))))


;;;; Cancelling and closing

(ert-deftest cmacs-brigade-cancel-releases-a-resumable-conversation ()
  "Cancelling a finished-but-resumable task releases everything it held.

It used to leave all of it in place -- the session, the sandbox and the
queued messages -- while returning t, because the return value of the
rejected transition was discarded."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-enqueue id "never delivered" "human")
    ;; The task has already finished, so it cannot become `cancelled' --
    ;; but it can stop being resumable, which is what was asked for.
    (should (cmacs-brigade-cancel-task id))
    (should-not (cmacs-brigade-conversation-p id))
    (should (= 0 (cmacs-brigade-mailbox-count id)))
    ;; And a later send finds nothing to continue.
    (cmacs-brigade-mailbox-send id "hello?" "human")
    (should-not (eq 'running (plist-get (cmacs-brigade-task-get id) :state)))))

(ert-deftest cmacs-brigade-cancel-stops-a-running-turn ()
  "Cancelling mid-turn reaches `cancelled' and reports honestly."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-send id "start another turn" "human")
    (should (eq 'running (plist-get (cmacs-brigade-task-get id) :state)))
    (should (cmacs-brigade-cancel-task id))
    (should (eq 'cancelled (plist-get (cmacs-brigade-task-get id) :state)))
    (should-not (cmacs-brigade-conversation-p id))))

(ert-deftest cmacs-brigade-close-conversation-releases-it ()
  "Closing ends the conversation but leaves the log readable."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-close-conversation id "done with it")
    (should-not (cmacs-brigade-conversation-p id))
    (should (eq 'done (plist-get (cmacs-brigade-task-get id) :state)))
    (should (cmacs-brigade-log-read id))))

(ert-deftest cmacs-brigade-sweep-skips-running-conversations ()
  "The idle sweep never retires something a worker is still using.

The worker holds its own references, so freeing is memory-safe, but the
completion callback would fire into a conversation that no longer
exists -- trading a leak for a crash."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-send id "keep me busy" "human")
    (should (gethash id cmacs-brigade--runs))
    (should (= 0 (cmacs-brigade-sweep-conversations t)))
    (should (cmacs-brigade-conversation-p id))))

(ert-deftest cmacs-brigade-sweep-reports-undelivered-mail ()
  "Sweeping a conversation with mail queued records it rather than
dropping the messages quietly.

The task itself usually stays `done' -- the run succeeded, it is the
messages that were lost -- so the record is the log entry."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (cmacs-brigade-mailbox-enqueue id "stranded" "human")
    (should (= 1 (cmacs-brigade-sweep-conversations t)))
    (should-not (cmacs-brigade-conversation-p id))
    (should (cl-find-if (lambda (e)
                          (equal "swept" (alist-get 'state e)))
                        (cmacs-brigade-log-read id)))))

(ert-deftest cmacs-brigade-sweep-honours-idleness ()
  "A conversation touched recently is not swept."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (let ((cmacs-brigade-conversation-ttl 3600))
      (should (= 0 (cmacs-brigade-sweep-conversations)))
      (should (cmacs-brigade-conversation-p id)))
    (let ((cmacs-brigade-conversation-ttl -1))
      (should (= 1 (cmacs-brigade-sweep-conversations)))
      (should-not (cmacs-brigade-conversation-p id)))))


;;;; Counting and ordering

(ert-deftest cmacs-brigade-outstanding-counts-parked-work ()
  "A parked task with mail is outstanding; the live count ignores it.

`live-count' is the concurrency gate and must keep counting processes
only, or a parked conversation would go on holding a slot."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-task id
    (should (= 0 (cmacs-brigade-live-count)))
    (should (= 0 (cmacs-brigade-outstanding-count)))
    (cmacs-brigade-mailbox-enqueue id "waiting" "human")
    (should (= 0 (cmacs-brigade-live-count)))
    (should (= 1 (cmacs-brigade-outstanding-count)))))

(ert-deftest cmacs-brigade-queue-drains-oldest-first ()
  "The queue is FIFO by when a task became ready, not by hash order.

Bucket order is arbitrary but stable, so without this a task in a late
bucket loses to the same competitors on every drain -- real starvation
once a task can be re-queued repeatedly, which is what a conversation
does."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((cmacs-brigade-max-concurrent 1)
          (ids '("mbx-test-a" "mbx-test-b" "mbx-test-c")))
      (dolist (i ids)
        (cmacs-brigade-task-adopt i "mock.org" "mock-agent" "t")
        (cmacs-brigade-task-transition i 'queued))
      ;; One slot, so the drain must choose; it should choose the oldest.
      (cmacs-brigade--drain-queue)
      (should (equal "mbx-test-a"
                     (plist-get (car cmacs-brigade-mailbox-tests--starts) :task)))
      (cmacs-brigade--finish "mbx-test-a" 'done "x")
      (should (equal "mbx-test-b"
                     (plist-get (car cmacs-brigade-mailbox-tests--starts) :task)))
      (cmacs-brigade--finish "mbx-test-b" 'done "x")
      (should (equal "mbx-test-c"
                     (plist-get (car cmacs-brigade-mailbox-tests--starts)
                                :task))))))

(ert-deftest cmacs-brigade-resumed-turn-waits-its-turn ()
  "A conversation does not jump the queue by finishing.

Starting directly from the completion path would let a chatty
conversation re-take the slot it just released ahead of tasks that had
been waiting longer, making the release nominal."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((cmacs-brigade-max-concurrent 1)
          (chatty "mbx-test-chatty")
          (patient "mbx-test-patient"))
      (cmacs-brigade-task-adopt chatty "mock.org" "mock-agent" "t")
      (cmacs-brigade-task-transition chatty 'queued)
      (should (cmacs-brigade-start-task chatty))
      ;; Somebody else joins the queue while it runs.
      (cmacs-brigade-task-adopt patient "mock.org" "mock-agent" "t")
      (cmacs-brigade-task-transition patient 'queued)
      ;; And a follow-up for the running one arrives after that.
      (cmacs-brigade-mailbox-send chatty "one more" "human")
      (cmacs-brigade--finish chatty 'done "answer")
      ;; The slot goes to whoever was ready first, which is the patient
      ;; task -- it entered the queue before the follow-up arrived.
      (should (equal patient
                     (plist-get (car cmacs-brigade-mailbox-tests--starts)
                                :task)))
      (should (= 1 (cmacs-brigade-mailbox-count chatty))))))


;;;; Accounting

(ert-deftest cmacs-brigade-progress-accumulates ()
  "Per-turn figures add up rather than replacing the total.

A resumed CLI turn's report carries that invocation's usage only, so
assigning it made every turn overwrite the conversation's cost with the
last turn's -- silently under-reporting the one number a budget acts on."
  (skip-unless (and (cmacs-brigade-mailbox-tests--runnable-p)
                    (fboundp 'cmacs-brigade-task-progress-add)))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((id "mbx-test-acct"))
      (cmacs-brigade-task-adopt id "mock.org" "mock-agent" "t")
      (cmacs-brigade-task-progress-add id 2 100 50 1000)
      (cmacs-brigade-task-progress-add id 3 200 70 2500)
      (let ((r (cmacs-brigade-task-get id)))
        (should (= 5 (plist-get r :turns)))
        (should (= 300 (plist-get r :in-tokens)))
        (should (= 120 (plist-get r :out-tokens)))
        (should (= 3500 (plist-get r :cost-micros)))))))

(ert-deftest cmacs-brigade-cli-report-accumulates-and-captures-session ()
  "A CLI report adds to the totals and records the session id."
  (skip-unless (and (cmacs-brigade-mailbox-tests--runnable-p)
                    (fboundp 'cmacs-brigade--parse-cli-report)))
  (cmacs-brigade-mailbox-tests--with-task id
    (let ((r1 "{\"result\":\"hi\",\"num_turns\":1,\"session_id\":\"sess-1\",\"total_cost_usd\":0.001,\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}")
          (r2 "{\"result\":\"ho\",\"num_turns\":2,\"session_id\":\"sess-2\",\"total_cost_usd\":0.002,\"usage\":{\"input_tokens\":20,\"output_tokens\":7}}"))
      (should (equal "hi" (cmacs-brigade--parse-cli-report r1 id)))
      (should (equal "sess-1" (cmacs-brigade-conversation-session-id id)))
      (should (equal "ho" (cmacs-brigade--parse-cli-report r2 id)))
      ;; Re-captured, not pinned: some CLI versions fork a new id on
      ;; resume, and reusing the first would truncate history from the
      ;; turn after next with nothing to show for it.
      (should (equal "sess-2" (cmacs-brigade-conversation-session-id id)))
      (let ((rec (cmacs-brigade-task-get id)))
        (should (= 3 (plist-get rec :turns)))
        (should (= 30 (plist-get rec :in-tokens)))
        (should (= 3000 (plist-get rec :cost-micros)))))))

(ert-deftest cmacs-brigade-cli-argv-carries-the-session ()
  "A resumed CLI turn asks to resume; a first turn does not."
  (skip-unless (and (cmacs-brigade-mailbox-tests--runnable-p)
                    (fboundp 'cmacs-brigade--worker-command)))
  (let* ((agent '(:name test :model "claude-code/opus"))
         (fresh (cmacs-brigade--worker-command 'claude-code agent "/tmp/p" nil))
         (resumed (cmacs-brigade--worker-command 'claude-code agent "/tmp/p"
                                                 nil "sess-9")))
    (should-not (member "--resume" fresh))
    (should (member "--resume" resumed))
    (should (member "sess-9" resumed))
    ;; An empty session id is not a session.
    (should-not (member "--resume"
                        (cmacs-brigade--worker-command
                         'claude-code agent "/tmp/p" nil "")))
    ;; opencode spells it differently.
    (let ((oc (cmacs-brigade--worker-command
               'opencode '(:name test :model "opencode/x") "/tmp/p" nil "s1")))
      (should (member "--session" oc))
      (should (member "s1" oc)))))


;;;; Tools

(ert-deftest cmacs-brigade-mailbox-tools-are-registered ()
  "All five reach every surface, in the `mailbox' group."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (dolist (n '(agent-send agent-inbox agent-drop agent-log agent-close))
    (let ((tool (cmacs-brigade-registry-get 'tool n)))
      (should tool)
      (should (eq 'mailbox (cmacs-brigade-tool-group tool)))))
  ;; The two that start work or destroy queued messages are marked so.
  (should (cmacs-brigade-tool-destructive
           (cmacs-brigade-registry-get 'tool 'agent-send)))
  ;; Reading a log is not destructive -- a sidecar debugger must be able
  ;; to have it without also being able to spend money.
  (should-not (cmacs-brigade-tool-destructive
               (cmacs-brigade-registry-get 'tool 'agent-log))))

(ert-deftest cmacs-brigade-mailbox-tool-wire-names ()
  "The wire names are the snake_case ones the surfaces call."
  (skip-unless (cmacs-brigade-mailbox-tests--available-p))
  (dolist (pair '((agent-send . "agent_send") (agent-inbox . "agent_inbox")
                  (agent-drop . "agent_drop") (agent-log . "agent_log")
                  (agent-close . "agent_close")))
    (should (equal (cdr pair)
                   (cmacs-brigade-tool-wire-name
                    (cmacs-brigade-registry-get 'tool (car pair)))))))

(ert-deftest cmacs-brigade-mailbox-tools-pass-the-allowlist-gate ()
  "An agent granted `mailbox' gets them; one granted only `agent' does not."
  (skip-unless (and (cmacs-brigade-mailbox-tests--available-p)
                    (fboundp 'cmacs-brigade-tool-allowed-p)))
  (should (cmacs-brigade-tool-allowed-p "mailbox" "agent_send"))
  (should (cmacs-brigade-tool-allowed-p "*" "agent_log"))
  (should-not (cmacs-brigade-tool-allowed-p "agent" "agent_send"))
  (should (cmacs-brigade-tool-allowed-p "agent" "agent_status")))

(ert-deftest cmacs-brigade-agent-log-reads-a-task-you-never-spawned ()
  "The sidecar case: inspect another agent's run without being handed it."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (cmacs-brigade-log-append "mbx-test-other" "message" :turn 1
                              :text "go and break something" :from "human")
    (cmacs-brigade-log-append "mbx-test-other" "tool" :turn 1
                              :tool "bash" :error "exit 1")
    (cmacs-brigade-log-append "mbx-test-other" "reply" :turn 1
                              :text "I could not do it")
    (let ((out (cmacs-brigade-call-tool
                "agent_log" "{\"id\":\"mbx-test-other\"}" "someone-else")))
      (should (string-match-p "go and break something" out))
      (should (string-match-p "exit 1" out))
      (should (string-match-p "could not do it" out)))
    ;; Narrowed by kind, so a long run can be read in pieces.
    (let ((only (cmacs-brigade-call-tool
                 "agent_log"
                 "{\"id\":\"mbx-test-other\",\"kinds\":\"reply\"}" "x")))
      (should (string-match-p "could not do it" only))
      (should-not (string-match-p "go and break something" only)))))

(ert-deftest cmacs-brigade-mailbox-tools-report-errors-as-text ()
  "A bad request comes back as something the model can read and act on.

ai-glib's soft-error convention: a signalled error aborts the agent's
whole turn, a returned one lets it try something else."
  (skip-unless (cmacs-brigade-mailbox-tests--runnable-p))
  (cmacs-brigade-mailbox-tests--with-env
    (let ((out (cmacs-brigade-call-tool
                "agent_send" "{\"id\":\"nope\",\"message\":\"hi\"}" "x")))
      (should (stringp out))
      (should (string-match-p "\\(?:no such task\\|Could not send\\)" out)))
    (should (string-match-p "No such task"
                            (cmacs-brigade-call-tool
                             "agent_log" "{\"id\":\"nope\"}" "x")))))

(provide 'cmacs-brigade-mailbox-tests)

;;; cmacs-brigade-mailbox-tests.el ends here
