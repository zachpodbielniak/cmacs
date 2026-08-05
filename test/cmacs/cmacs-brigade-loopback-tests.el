;;; cmacs-brigade-loopback-tests.el --- Waking the asker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What matters here is not that a message gets sent -- it is *when* it
;; does not.  Delivering into a chat that is mid-stream interleaves with
;; the model's own turn; delivering while a draft sits in the compose
;; region sends the draft too; delivering twice makes the model think two
;; agents finished.  Each of those is quiet, and each is tested.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-loopback nil 'noerror)
(require 'cmacs-brigade-subagent nil 'noerror)
(require 'cmacs-ai-chat nil 'noerror)

(defun cmacs-brigade-loopback-tests--available-p ()
  (and (featurep 'cmacs-brigade-loopback)
       (fboundp 'cmacs-ai-chat-mode)))

(defmacro cmacs-brigade-loopback-tests--with-chat (&rest body)
  "Run BODY with BUF bound to a chat buffer and TARGET to its id."
  (declare (indent 0))
  `(let* ((buf (generate-new-buffer "*cmacs-ai: ert*"))
          (target (format "chat:%s" (buffer-name buf))))
     (unwind-protect
         (progn
           (with-current-buffer buf
             (cmacs-ai-chat-mode)
             (let ((inhibit-read-only t))
               (insert "* Conversation\n\n* Compose\n"))
             (setq-local cmacs-ai-chat--compose-marker (copy-marker (point-max)))
             (set-marker-insertion-type cmacs-ai-chat--compose-marker nil))
           ,@body)
       (when (buffer-live-p buf) (kill-buffer buf)))))

(defmacro cmacs-brigade-loopback-tests--capturing (var &rest body)
  "Run BODY with the chat send path stubbed, capturing what it would send."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'cmacs-ai-chat-send-compose)
              (lambda ()
                (setq ,var (string-trim
                            (buffer-substring-no-properties
                             cmacs-ai-chat--compose-marker (point-max))))
                (delete-region cmacs-ai-chat--compose-marker (point-max)))))
     ,@body))


;;;; Finding a target

(ert-deftest cmacs-brigade-loopback-notices-the-chat-it-is-in ()
  "A spawn running inside a chat's tool loop knows which chat that is.

The chat layer executes tools with its own buffer current, which is the
only moment the origin is knowable -- by the time the subagent finishes
that context is long gone."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (cmacs-brigade-loopback-tests--with-chat
    (with-current-buffer buf
      (should (equal target (cmacs-brigade-loopback-current-target))))
    ;; and not from anywhere else
    (with-temp-buffer
      (should-not (cmacs-brigade-loopback-current-target)))
    (should (assoc target (cmacs-brigade-loopback-targets)))))

(ert-deftest cmacs-brigade-loopback-target-routes-by-prefix ()
  "The client is chosen by the target's prefix, and unknown ones are inert."
  (skip-unless (featurep 'cmacs-brigade-loopback))
  (should (cmacs-brigade-loopback-target-client "chat:whatever"))
  (should-not (cmacs-brigade-loopback-target-client "nosuchclient:x"))
  (should-not (cmacs-brigade-loopback-target-client nil))
  ;; An unroutable target must not raise on the finish path.
  (should-not (cmacs-brigade-loopback-deliver "nosuchclient:x" "hi")))


;;;; When not to deliver

(ert-deftest cmacs-brigade-loopback-waits-for-a-half-typed-draft ()
  "A message never takes the human's unsent draft along with it."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (cmacs-brigade-loopback-tests--with-chat
    (should (cmacs-brigade-loopback-ready-p target))
    (with-current-buffer buf
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "something I was typing")))
    (should-not (cmacs-brigade-loopback-ready-p target))
    ;; Not sent, and not lost either: it is queued.
    (let ((cmacs-brigade-loopback--queue nil)
          (sent nil))
      (cmacs-brigade-loopback-tests--capturing sent
        (should-not (cmacs-brigade-loopback-deliver target "wake up")))
      (should-not sent)
      (should (= 1 (length cmacs-brigade-loopback--queue))))))

(ert-deftest cmacs-brigade-loopback-waits-while-a-reply-streams ()
  "Mid-stream is the one moment a turn must not be inserted."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (cmacs-brigade-loopback-tests--with-chat
    (with-current-buffer buf
      (setq-local cmacs-ai-chat--assistant-marker (copy-marker (point-max))))
    (should-not (cmacs-brigade-loopback-ready-p target))
    (with-current-buffer buf
      (setq-local cmacs-ai-chat--assistant-marker nil)
      (setq-local cmacs-ai-chat--pending-tool-uses '(("t" "{}" "id"))))
    (should-not (cmacs-brigade-loopback-ready-p target))
    (with-current-buffer buf
      (setq-local cmacs-ai-chat--pending-tool-uses nil))
    (should (cmacs-brigade-loopback-ready-p target))))

(ert-deftest cmacs-brigade-loopback-drops-a-dead-target ()
  "A chat that was closed is not queued for forever."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (let (target)
    (cmacs-brigade-loopback-tests--with-chat
      (setq target (format "chat:%s" (buffer-name buf))))
    ;; buffer is gone now
    (should-not (cmacs-brigade-loopback-live-p target))
    (let ((cmacs-brigade-loopback--queue nil))
      (should-not (cmacs-brigade-loopback-deliver target "wake up"))
      (should-not cmacs-brigade-loopback--queue))))

(ert-deftest cmacs-brigade-loopback-queue-drains-when-free ()
  "A queued message goes out once the target is idle again."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (cmacs-brigade-loopback-tests--with-chat
    (with-current-buffer buf
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "draft")))
    (let ((cmacs-brigade-loopback--queue nil)
          (cmacs-brigade-loopback--timer nil)
          (sent nil))
      (cmacs-brigade-loopback-deliver target "wake up")
      (should cmacs-brigade-loopback--queue)
      ;; The human sends their draft; the target frees up.
      (with-current-buffer buf
        (delete-region cmacs-ai-chat--compose-marker (point-max)))
      (cmacs-brigade-loopback-tests--capturing sent
        (cmacs-brigade-loopback--drain))
      (should (equal sent "wake up"))
      (should-not cmacs-brigade-loopback--queue)
      (when cmacs-brigade-loopback--timer
        (cancel-timer cmacs-brigade-loopback--timer)
        (setq cmacs-brigade-loopback--timer nil)))))

(ert-deftest cmacs-brigade-loopback-queue-gives-up-eventually ()
  "A conversation left mid-stream for long enough stops being waited on."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (cmacs-brigade-loopback-tests--with-chat
    (with-current-buffer buf
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "draft")))
    (let ((cmacs-brigade-loopback--queue
           (list (list target "wake up" (- (float-time) 1))))
          (cmacs-brigade-loopback--timer nil))
      (cmacs-brigade-loopback--drain)
      (should-not cmacs-brigade-loopback--queue))))


;;;; The whole loop

(ert-deftest cmacs-brigade-loopback-spawn-to-finish ()
  "A spawn from a chat records it, and finishing delivers a turn back."
  (skip-unless (and (cmacs-brigade-loopback-tests--available-p)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (cmacs-brigade-agent-reload)
  (let* ((dir (make-temp-file "cmacs-brigade-loop" t))
         (cmacs-brigade-plan-directory dir)
         (cmacs-brigade-subagent-plan (expand-file-name "sub.org" dir))
         id sent)
    (unwind-protect
        (cmacs-brigade-loopback-tests--with-chat
          (with-current-buffer buf
            (cl-letf (((symbol-function 'cmacs-brigade-start-task)
                       (lambda (_) t)))
              (setq id (cmacs-brigade-subagent-spawn
                        "general" "do a thing" "A thing"))))
          (should (equal target (cmacs-brigade-loopback-task-target id)))
          (cmacs-brigade-loopback-tests--capturing sent
            (cmacs-brigade-loopback-on-finished id 'done "the output"))
          (should sent)
          (should (string-match-p (regexp-quote id) sent))
          (should (string-match-p "agent_result" sent))
          ;; Once only: a re-fired hook would tell the model a second
          ;; agent had finished.
          (setq sent nil)
          (cmacs-brigade-loopback-tests--capturing sent
            (cmacs-brigade-loopback-on-finished id 'done "the output"))
          (should-not sent))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p dir (buffer-file-name b)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-loopback-ignores-a-task-with-no-target ()
  "A task nobody asked to be told about notifies nothing."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (let ((sent nil))
    (cl-letf (((symbol-function 'cmacs-brigade-loopback-task-target)
               (lambda (_) nil))
              ((symbol-function 'cmacs-brigade-loopback-deliver)
               (lambda (&rest _) (setq sent t))))
      (cmacs-brigade-loopback-on-finished "no-such-task" 'done nil)
      (should-not sent))))

(ert-deftest cmacs-brigade-loopback-can-be-turned-off ()
  "With the feature off, a recorded target is still not disturbed."
  (skip-unless (cmacs-brigade-loopback-tests--available-p))
  (let ((cmacs-brigade-loopback-enabled nil)
        (sent nil))
    (cl-letf (((symbol-function 'cmacs-brigade-loopback-task-target)
               (lambda (_) "chat:whatever"))
              ((symbol-function 'cmacs-brigade-loopback-deliver)
               (lambda (&rest _) (setq sent t))))
      (cmacs-brigade-loopback-on-finished "t" 'done nil)
      (should-not sent))))

(ert-deftest cmacs-brigade-loopback-is-on-the-finished-hook ()
  "Registered, and registered eagerly.

The recurring failure in this subsystem is a capability that exists and
nothing invoking it; the hook has to be in place before the first run
ends, which is well before anyone opens the dashboard."
  (skip-unless (featurep 'cmacs-brigade-loopback))
  (should (memq #'cmacs-brigade-loopback-on-finished
                cmacs-brigade-run-finished-functions))
  (should (cmacs-brigade-registry-get 'client 'chat)))

(provide 'cmacs-brigade-loopback-tests)

;;; cmacs-brigade-loopback-tests.el ends here
