;;; cmacs-brigade-undo-tests.el --- Undo for agent actions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The action log and its undo (lisp/cmacs/cmacs-brigade-undo.el).
;;
;; The dispatch tests call `cmacs-brigade-call-tool' in-process with
;; tools registered here, in real buffers and real files: capture
;; before the handler, the change group in the buffer's own undo list,
;; staleness, force, per-task order, caller isolation for `action_undo'
;; and `action_log', the ring bound, no disk writes, redacted display.
;; The capture-function tests run each shipped capture's record through
;; its life (capture -> :after -> :stale -> :inverse) with the
;; subsystem DEFUNs stubbed -- that proves the inverses' logic, not the
;; compositor's; test/cmacs/cmacs-rig-undo-tests.el does the real thing
;; over MCP.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-brigade-registry nil t)
(require 'cmacs-brigade-tools nil t)
(require 'cmacs-brigade-undo nil t)
(require 'cmacs-brigade-undo-capture nil t)

(defvar cmacs-brigade-auto-approve)
(defvar cmacs-brigade-undo--log)
(defvar cmacs-brigade-undo--next-id)
(defvar cmacs-brigade-undo-log-size)
(defvar cmacs-brigade-undo-max-bytes)
(defvar cmacs-brigade-undo-persist-metadata)
(defvar cmacs-brigade-undo-log-all-callers)
(defvar cmacs-brigade-undo--wallpaper)
(defvar cmacs-context--approved)

(defconst cmacs-brigade-undo-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name
                                 (expand-file-name "test/cmacs/x"))))
  "The source tree, captured while this file loads.")

(defvar cmacs-brigade-undo-tests--cleaned nil
  "Set by the test tool's record :cleanup.")

(defun cmacs-brigade-undo-tests--available-p ()
  "Non-nil when the undo machinery is loaded."
  (and (fboundp 'cmacs-brigade-call-tool)
       (fboundp 'cmacs-brigade-undo--begin)
       (fboundp 'cmacs-brigade-tool-undo)))

(defun cmacs-brigade-undo-tests--register ()
  "Register the tools these tests call."
  (cmacs-brigade-deftool undo-test-replace
      "Replace FROM with TO in BUFFER."
      ((buffer string "Buffer")
       (from string "Text to replace")
       (to string "Replacement"))
    :destructive t
    :undo (cmacs-brigade-undo-buffer-record buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (unless (search-forward from nil t) (error "not found: %s" from))
        (replace-match to t t))
      (goto-char (point-max))
      "replaced"))
  (cmacs-brigade-deftool undo-test-three
      "Insert three words into BUFFER, as three separate changes."
      ((buffer string "Buffer"))
    :destructive t
    :undo 'cmacs-brigade-undo-capture-buffer-text
    (with-current-buffer buffer
      (dolist (w '("one " "two " "three "))
        (goto-char (point-min))
        (insert w)
        (undo-boundary))
      "inserted"))
  (cmacs-brigade-deftool undo-test-irrev
      "Do something that cannot be undone."
      ()
    :destructive t
    :undo '(irreversible "it cannot be")
    "done")
  (cmacs-brigade-deftool undo-test-undeclared
      "Destructive, no decision."
      ()
    :destructive t
    "done")
  (cmacs-brigade-deftool undo-test-read
      "Read something."
      ()
    "read")
  (cmacs-brigade-deftool undo-test-capture-fails
      "A tool whose capture signals."
      ()
    :destructive t
    :undo (error "capture boom")
    "ran anyway")
  (cmacs-brigade-deftool undo-test-fails
      "A tool that edits and then fails."
      ((buffer string "Buffer"))
    :destructive t
    :undo (cmacs-brigade-undo-buffer-record buffer)
    (with-current-buffer buffer (insert "partial"))
    (error "handler boom"))
  (cmacs-brigade-deftool undo-test-cleanup
      "A tool whose record must be released."
      ((n integer "Anything"))
    :destructive t
    :undo (list :summary "nothing really" :object (list 'n n)
                :inverse #'ignore
                :cleanup (lambda (_r)
                           (push n cmacs-brigade-undo-tests--cleaned)))
    (format "n=%d" n))
  (cmacs-brigade-deftool undo-test-write
      "Write CONTENT to FILE."
      ((file string "File")
       (content string "Text"))
    :destructive t
    :undo (cmacs-brigade-undo-file-record file)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region content nil file nil 'silent))
    "written"))

(defconst cmacs-brigade-undo-tests--tools
  '(undo-test-replace undo-test-three undo-test-irrev undo-test-undeclared
    undo-test-read undo-test-capture-fails undo-test-fails
    undo-test-cleanup undo-test-write)
  "The tools `cmacs-brigade-undo-tests--register' defines.")

(defmacro cmacs-brigade-undo-tests--with (&rest body)
  "Run BODY with an empty action log and the test tools registered."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (cmacs-brigade-undo-tests--available-p))
     (let ((cmacs-brigade-undo--log nil)
           (cmacs-brigade-undo--next-id 0)
           (cmacs-brigade-undo-log-size 200)
           (cmacs-brigade-undo-persist-metadata nil)
           (cmacs-brigade-undo-log-all-callers nil)
           (cmacs-brigade-auto-approve t)
           (cmacs-brigade-undo-tests--cleaned nil))
       (cmacs-brigade-undo-tests--register)
       (unwind-protect (progn ,@body)
         (dolist (tool cmacs-brigade-undo-tests--tools)
           (cmacs-brigade-unregister-tool tool))))))

(defun cmacs-brigade-undo-tests--call (tool args &optional agent task)
  "Call TOOL with ARGS (a plist) as AGENT in TASK; return the result."
  (cmacs-brigade-call-tool tool (json-serialize (or args (make-hash-table)))
                           (or agent "tester") nil task))

(defmacro cmacs-brigade-undo-tests--buffer (text &rest body)
  "Run BODY with `buf' bound to a fresh buffer holding TEXT, undo on."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "undo-test")))
     (unwind-protect
         (progn
           (with-current-buffer buf
             (buffer-enable-undo)
             (insert ,text)
             (undo-boundary)
             (goto-char 3))
           ,@body)
       (when (buffer-live-p buf) (kill-buffer buf)))))

(defun cmacs-brigade-undo-tests--text (buf)
  "BUF's text."
  (with-current-buffer buf (buffer-string)))

(defun cmacs-brigade-undo-tests--last ()
  "The newest log entry."
  (car cmacs-brigade-undo--log))


;;;; Capture, inverse, staleness

(ert-deftest cmacs-brigade-undo-test-capture-and-inverse ()
  "The state before is captured; undoing restores the text and point."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "hello world"
      (should (equal (cmacs-brigade-undo-tests--call
                      "undo_test_replace"
                      (list :buffer (buffer-name buf) :from "world"
                            :to "agent"))
                     "replaced"))
      (should (equal (cmacs-brigade-undo-tests--text buf) "hello agent"))
      (let ((e (cmacs-brigade-undo-tests--last)))
        (should (eq (cmacs-brigade-action-state e) 'done))
        (should (equal (cmacs-brigade-action-tool e) "undo_test_replace"))
        (should (equal (cmacs-brigade-action-agent e) "tester"))
        (should (string-match-p "Undid #1"
                                (cmacs-brigade-undo-run e)))
        (should (eq (cmacs-brigade-action-state e) 'undone))
        (should (equal (cmacs-brigade-undo-tests--text buf) "hello world"))
        (should (= (with-current-buffer buf (point)) 3))
        ;; Undone once is undone.
        (should-error (cmacs-brigade-undo-run e)
                      :type 'cmacs-brigade-undo-error)))))

(ert-deftest cmacs-brigade-undo-test-change-group-amalgamated ()
  "Three separate changes by one call are one group in the buffer's undo."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "base"
      (cmacs-brigade-undo-tests--call "undo_test_three"
                                      (list :buffer (buffer-name buf)))
      (should (equal (cmacs-brigade-undo-tests--text buf)
                     "three two one base"))
      (with-current-buffer buf
        ;; ONE group: the first boundary-delimited run of the undo list
        ;; takes back all three, as a plain C-/ would.
        (let ((list (copy-sequence
                     (cmacs-brigade-undo--skip-boundaries buffer-undo-list))))
          (primitive-undo 1 list))
        (should (equal (buffer-string) "base"))))))

(ert-deftest cmacs-brigade-undo-test-inverse-prefers-undo-list ()
  "With the buffer's undo list intact, the log undoes through it."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "base"
      (cmacs-brigade-undo-tests--call "undo_test_three"
                                      (list :buffer (buffer-name buf)))
      (let* ((e (cmacs-brigade-undo-tests--last))
             (record (cmacs-brigade-action-record e))
             (group (cdr (assq buf (plist-get record :groups)))))
        (should group)
        (should (cmacs-brigade-undo--group-segment buf group))
        (cmacs-brigade-undo-run e)
        (should (equal (cmacs-brigade-undo-tests--text buf) "base"))
        ;; The undo is itself one change: C-/ re-applies the agent's edit.
        (with-current-buffer buf
          (primitive-undo 1 (copy-sequence
                             (cmacs-brigade-undo--skip-boundaries
                              buffer-undo-list)))
          (should (equal (buffer-string) "three two one base")))))))

(ert-deftest cmacs-brigade-undo-test-snapshot-keeps-later-user-edit ()
  "A user edit elsewhere is kept: the undo falls back to the snapshot region."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "alpha beta gamma"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace"
       (list :buffer (buffer-name buf) :from "beta" :to "BETA"))
      (with-current-buffer buf
        (goto-char (point-max))
        (insert " delta")
        (undo-boundary)
        (goto-char (point-min))
        (insert ">> ")
        (undo-boundary))
      (let ((e (cmacs-brigade-undo-tests--last)))
        (should-not (cmacs-brigade-undo--group-segment
                     buf (cdr (assq buf (plist-get (cmacs-brigade-action-record e)
                                                   :groups)))))
        (cmacs-brigade-undo-run e)
        (should (equal (cmacs-brigade-undo-tests--text buf)
                       ">> alpha beta gamma delta"))))))

(ert-deftest cmacs-brigade-undo-test-stale-refused-then-forced ()
  "Editing what the agent wrote makes the undo refuse; force overrides."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "one two three"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace"
       (list :buffer (buffer-name buf) :from "two" :to "TWO"))
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "TWO")
        (replace-match "Two!" t t))
      (let ((e (cmacs-brigade-undo-tests--last)))
        (let ((err (should-error (cmacs-brigade-undo-run e)
                                 :type 'cmacs-brigade-undo-stale)))
          (should (string-match-p "was changed since" (cadr err))))
        (should (eq (cmacs-brigade-action-state e) 'stale))
        (should (equal (cmacs-brigade-undo-tests--text buf) "one Two! three"))
        (cmacs-brigade-undo-run e 'force)
        (should (eq (cmacs-brigade-action-state e) 'undone))
        (should (equal (cmacs-brigade-undo-tests--text buf)
                       "one two three"))))))

(ert-deftest cmacs-brigade-undo-test-killed-buffer-is-stale ()
  "An edit to a buffer killed since refuses rather than signals oddly."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "x y"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "y" :to "z"))
      (kill-buffer buf)
      (should-error (cmacs-brigade-undo-run (cmacs-brigade-undo-tests--last))
                    :type 'cmacs-brigade-undo-stale))))

(ert-deftest cmacs-brigade-undo-test-newer-action-must-go-first ()
  "An older action on the same buffer refuses while a newer one stands."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "a b"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "a" :to "A"))
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "b" :to "B"))
      (let ((older (cadr cmacs-brigade-undo--log))
            (newer (car cmacs-brigade-undo--log)))
        (let ((err (should-error (cmacs-brigade-undo-run older)
                                 :type 'cmacs-brigade-undo-stale)))
          (should (string-match-p "#2 undo_test_replace changed the same"
                                  (cadr err))))
        (cmacs-brigade-undo-run newer)
        (cmacs-brigade-undo-run older)
        (should (equal (cmacs-brigade-undo-tests--text buf) "a b"))))))


;;;; What is logged, and how

(ert-deftest cmacs-brigade-undo-test-what-is-logged ()
  "Reads are not logged; undeclared and declared irreversibles are."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--call "undo_test_read" nil)
    (should (null cmacs-brigade-undo--log))
    (cmacs-brigade-undo-tests--call "undo_test_undeclared" nil)
    (let ((e (cmacs-brigade-undo-tests--last)))
      (should (eq (cmacs-brigade-action-state e) 'irreversible))
      (should (equal (cmacs-brigade-action-reason e) "no undo declared")))
    (cmacs-brigade-undo-tests--call "undo_test_irrev" nil)
    (should (equal (cmacs-brigade-action-reason (cmacs-brigade-undo-tests--last))
                   "it cannot be"))
    (should (equal (cmacs-brigade-undo-tests--call "undo_test_capture_fails"
                                                   nil)
                   "ran anyway"))
    (should (string-match-p "could not be captured: capture boom"
                            (cmacs-brigade-action-reason
                             (cmacs-brigade-undo-tests--last))))))

(ert-deftest cmacs-brigade-undo-test-failed-call-not-logged ()
  "A call that fails is not logged, and its change group is closed."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "text"
      (should (string-prefix-p
               "Error: handler boom"
               (cmacs-brigade-undo-tests--call
                "undo_test_fails" (list :buffer (buffer-name buf)))))
      (should (null cmacs-brigade-undo--log))
      ;; Still one group: the partial edit goes in one C-/.
      (with-current-buffer buf
        (should (listp buffer-undo-list))
        (primitive-undo 1 (copy-sequence
                           (cmacs-brigade-undo--skip-boundaries
                            buffer-undo-list)))
        (should (equal (buffer-string) "text"))))))

(ert-deftest cmacs-brigade-undo-test-async-path-logs ()
  "`cmacs-brigade-call-tool-async' logs as the blocking path does."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "p q"
      (let (status)
        (cmacs-brigade-call-tool-async
         "undo_test_replace"
         (json-serialize (list :buffer (buffer-name buf) :from "q" :to "Q"))
         (lambda (s _text) (setq status s))
         "dbus")
        (should (eq status 'ok)))
      (let ((e (cmacs-brigade-undo-tests--last)))
        (should (eq (cmacs-brigade-action-surface e) 'dbus))
        (cmacs-brigade-undo-run e)
        (should (equal (cmacs-brigade-undo-tests--text buf) "p q"))))))

(ert-deftest cmacs-brigade-undo-test-ring-bound ()
  "The log keeps `cmacs-brigade-undo-log-size' entries and releases the rest."
  (cmacs-brigade-undo-tests--with
    (let ((cmacs-brigade-undo-log-size 3))
      (dotimes (i 5)
        (cmacs-brigade-undo-tests--call "undo_test_cleanup" (list :n i)))
      (should (equal (mapcar #'cmacs-brigade-action-id cmacs-brigade-undo--log)
                     '(5 4 3)))
      (should (equal (sort (copy-sequence cmacs-brigade-undo-tests--cleaned) #'<)
                     '(0 1))))))

(ert-deftest cmacs-brigade-undo-test-no-disk-writes-by-default ()
  "Nothing reaches disk unless the metadata journal is turned on."
  (cmacs-brigade-undo-tests--with
    (let* ((state (make-temp-file "undo-state" t))
           (process-environment (cons (concat "XDG_STATE_HOME=" state)
                                      process-environment))
           (file (expand-file-name "f.txt" state)))
      (unwind-protect
          (progn
            (with-temp-file file (insert "secret contents"))
            (cmacs-brigade-undo-tests--call
             "undo_test_write" (list :file file :content "new"))
            (cmacs-brigade-undo-tests--call "undo_test_irrev" nil)
            (should (= (length cmacs-brigade-undo--log) 2))
            (should-not (file-exists-p (expand-file-name "cmacs" state)))
            ;; Opted in: metadata only, private.
            (let ((cmacs-brigade-undo-persist-metadata t))
              (cmacs-brigade-undo-tests--call
               "undo_test_write" (list :file file :content "newer")))
            (let ((journal (expand-file-name "cmacs/undo/actions.jsonl" state)))
              (should (file-exists-p journal))
              (should (= (file-modes journal) #o600))
              (should (= (file-modes (file-name-directory journal)) #o700))
              (let ((text (with-temp-buffer (insert-file-contents journal)
                                            (buffer-string))))
                (should (string-match-p "undo_test_write" text))
                (should-not (string-match-p "secret\\|newer\\|contents"
                                            text)))))
        (delete-directory state t)))))

(ert-deftest cmacs-brigade-undo-test-redacted-display ()
  "Arguments shown to a model go through `cmacs-redact-text'."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "public"
      (cl-letf (((symbol-function 'cmacs-redact-text)
                 (lambda (s &rest _)
                   (replace-regexp-in-string "hunter2" "[R]" s))))
        (cmacs-brigade-undo-tests--call
         "undo_test_replace"
         (list :buffer (buffer-name buf) :from "public" :to "hunter2"))
        (let ((line (cmacs-brigade-undo-entry-line
                     (cmacs-brigade-undo-tests--last) 'strict)))
          (should (string-match-p "to=\\[R\\]" line))
          (should-not (string-match-p "hunter2" line)))))))


;;;; Per task, per agent, caller isolation

(ert-deftest cmacs-brigade-undo-test-task-order-and-stop ()
  "A task's actions are undone newest first, stopping at an irreversible one."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "a b"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "a" :to "A")
       "worker" "T1")
      (cmacs-brigade-undo-tests--call "undo_test_irrev" nil "worker" "T1")
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "b" :to "B")
       "worker" "T1")
      ;; Another task's action in between is not touched.
      (cmacs-brigade-undo-tests--call "undo_test_cleanup" (list :n 7)
                                      "other" "T2")
      (let ((outcome (cmacs-brigade-undo-task "T1")))
        (should (= (length (car outcome)) 1))
        (should (string-match-p "Stopped at #2 undo_test_irrev.*it cannot be"
                                (cdr outcome))))
      (should (equal (cmacs-brigade-undo-tests--text buf) "A b"))
      (should (eq (cmacs-brigade-action-state (cmacs-brigade-undo-entry 1))
                  'done))
      (should (eq (cmacs-brigade-action-state (cmacs-brigade-undo-entry 4))
                  'done)))))

(ert-deftest cmacs-brigade-undo-test-agent-undo ()
  "`cmacs-brigade-undo-agent' undoes one agent's actions only."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "x y"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "x" :to "X")
       "alice")
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "y" :to "Y")
       "bob")
      ;; bob's newer edit of the same buffer is in the way of alice's.
      (should (cdr (cmacs-brigade-undo-agent "alice")))
      (cmacs-brigade-undo-agent "bob")
      (cmacs-brigade-undo-agent "alice")
      (should (equal (cmacs-brigade-undo-tests--text buf) "x y")))))

(ert-deftest cmacs-brigade-undo-test-action-undo-own-only ()
  "`action_undo' undoes the caller's own actions, never another's."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "mine"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "mine"
                                 :to "theirs")
       "mcp" "task-a")
      ;; Another task: told there is no such action of theirs.
      (should (string-match-p
               "No action #1 among yours"
               (cmacs-brigade-undo-tests--call "action_undo" (list :id 1)
                                               "mcp" "task-b")))
      ;; An unscoped MCP client is not task-a either.
      (should (string-match-p
               "No action #1 among yours"
               (cmacs-brigade-undo-tests--call "action_undo" (list :id 1)
                                               "mcp")))
      (should (equal (cmacs-brigade-undo-tests--text buf) "theirs"))
      (should (string-match-p
               "Undid #1"
               (cmacs-brigade-undo-tests--call "action_undo" nil
                                               "mcp" "task-a")))
      (should (equal (cmacs-brigade-undo-tests--text buf) "mine"))
      ;; The undo call itself is logged as having nothing to undo.
      (should (eq (cmacs-brigade-action-state (cmacs-brigade-undo-tests--last))
                  'nothing)))))

(ert-deftest cmacs-brigade-undo-test-action-undo-refuses-stale ()
  "`action_undo' reports the staleness refusal as a tool error."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "keep"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "keep"
                                 :to "agent") "a1")
      (with-current-buffer buf (goto-char (point-max)) (insert "!user"))
      (should (string-match-p
               "\\`Error: .*Not undoing #1.*was changed since"
               (cmacs-brigade-undo-tests--call "action_undo" (list :id 1)
                                               "a1")))
      (should (equal (cmacs-brigade-undo-tests--text buf) "agent!user")))))

(ert-deftest cmacs-brigade-undo-test-action-log-own-only ()
  "`action_log' lists the caller's own actions; all callers need a grant."
  (cmacs-brigade-undo-tests--with
    (cl-letf (((symbol-function 'cmacs-redact-text) (lambda (s &rest _) s)))
      (cmacs-brigade-undo-tests--call "undo_test_irrev" nil "a1")
      (should (string-match-p "#1 .*undo_test_irrev"
                              (cmacs-brigade-undo-tests--call
                               "action_log" nil "a1")))
      (should (equal (cmacs-brigade-undo-tests--call "action_log" nil "a2")
                     "No actions."))
      (should (string-match-p "\\`Error: Not granted"
                              (cmacs-brigade-undo-tests--call
                               "action_log" (list :all t) "a2")))
      (let ((cmacs-brigade-undo-log-all-callers '("a2")))
        (should (string-match-p "#1 .*undo_test_irrev"
                                (cmacs-brigade-undo-tests--call
                                 "action_log" (list :all t) "a2")))))))

(ert-deftest cmacs-brigade-undo-test-global-undo-command ()
  "`cmacs-brigade-undo' with N undoes the last N, passing irreversibles."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--buffer "1 2"
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "1" :to "one"))
      (cmacs-brigade-undo-tests--call "undo_test_irrev" nil)
      (cmacs-brigade-undo-tests--call
       "undo_test_replace" (list :buffer (buffer-name buf) :from "2" :to "two"))
      (cmacs-brigade-undo)
      (should (equal (cmacs-brigade-undo-tests--text buf) "one 2"))
      (cmacs-brigade-undo 5)
      (should (equal (cmacs-brigade-undo-tests--text buf) "1 2")))))

(ert-deftest cmacs-brigade-undo-test-actions-buffer ()
  "The log buffer lists every entry and refreshes on change."
  (cmacs-brigade-undo-tests--with
    (cmacs-brigade-undo-tests--call "undo_test_irrev" nil)
    (save-window-excursion
      (cmacs-brigade-actions)
      (with-current-buffer "*cmacs agent actions*"
        (should (= (length tabulated-list-entries) 1))
        (cmacs-brigade-undo-tests--call "undo_test_undeclared" nil)
        (should (= (length tabulated-list-entries) 2))
        (goto-char (point-min))
        (should (search-forward "no undo declared" nil t))
        (kill-buffer)))))


;;;; Files

(ert-deftest cmacs-brigade-undo-test-file-write ()
  "A file write is undone to the old bytes; a later change refuses."
  (cmacs-brigade-undo-tests--with
    (let* ((dir (make-temp-file "undo-file" t))
           (file (expand-file-name "a.txt" dir))
           (trash-directory (expand-file-name "trash" dir)))
      (unwind-protect
          (progn
            (with-temp-file file (insert "old"))
            (set-file-modes file #o640)
            (cmacs-brigade-undo-tests--call
             "undo_test_write" (list :file file :content "new"))
            (cmacs-brigade-undo-run (cmacs-brigade-undo-tests--last))
            (should (equal (with-temp-buffer (insert-file-contents file)
                                             (buffer-string))
                           "old"))
            (should (= (file-modes file) #o640))
            ;; Changed after the agent: refused.
            (cmacs-brigade-undo-tests--call
             "undo_test_write" (list :file file :content "agent"))
            (with-temp-file file (insert "user"))
            (should-error (cmacs-brigade-undo-run
                           (cmacs-brigade-undo-tests--last))
                          :type 'cmacs-brigade-undo-stale)
            ;; A created file goes to the trash, not away.
            (let ((created (expand-file-name "b.txt" dir)))
              (cmacs-brigade-undo-tests--call
               "undo_test_write" (list :file created :content "x"))
              (cmacs-brigade-undo-run (cmacs-brigade-undo-tests--last))
              (should-not (file-exists-p created))
              (should (directory-files trash-directory nil "b\\.txt"))))
        (delete-directory dir t)))))

(ert-deftest cmacs-brigade-undo-test-file-too-large ()
  "A file over the bound is irreversible with a reason, unless backed up."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let* ((dir (make-temp-file "undo-big" t))
         (file (expand-file-name "big" dir))
         (cmacs-brigade-undo-max-bytes 4))
    (unwind-protect
        (progn
          (with-temp-file file (insert "0123456789"))
          (should (string-match-p
                   "more than"
                   (cmacs-brigade-undo--irreversible-reason
                    (cmacs-brigade-undo-file-record file)))))
      (delete-directory dir t))))


;;;; The shipped capture functions, with their subsystems stubbed

(defun cmacs-brigade-undo-tests--cycle (record &optional result)
  "Take RECORD through :after with RESULT; return the completed record."
  (should (consp record))
  (should-not (cmacs-brigade-undo--irreversible-p record))
  (if-let* ((after (plist-get record :after)))
      (funcall after record result)
    record))

(defun cmacs-brigade-undo-tests--undo (record)
  "Check RECORD is not stale and run its inverse."
  (when-let* ((stale (plist-get record :stale)))
    (should-not (funcall stale record)))
  (funcall (plist-get record :inverse) record))

(defun cmacs-brigade-undo-tests--stale-p (record)
  "Non-nil when RECORD's staleness check refuses."
  (and (plist-get record :stale) (funcall (plist-get record :stale) record)))

(ert-deftest cmacs-brigade-undo-test-capture-create-and-kill-buffer ()
  "create_buffer's inverse kills it if unchanged; kill_buffer's brings it back."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let* ((name (generate-new-buffer-name "undo-created"))
         (rec (cmacs-brigade-undo-capture-create-buffer name nil)))
    (get-buffer-create name)
    (setq rec (cmacs-brigade-undo-tests--cycle rec name))
    (cmacs-brigade-undo-tests--undo rec)
    (should-not (get-buffer name)))
  ;; Changed since it was created: refused.
  (let* ((name (generate-new-buffer-name "undo-created"))
         (rec (cmacs-brigade-undo-capture-create-buffer name nil)))
    (get-buffer-create name)
    (setq rec (cmacs-brigade-undo-tests--cycle rec name))
    (with-current-buffer name (insert "user"))
    (should (cmacs-brigade-undo-tests--stale-p rec))
    (kill-buffer name))
  (let ((b (generate-new-buffer "undo-killed")))
    (with-current-buffer b (text-mode) (insert "unsaved words") (goto-char 3))
    (let* ((name (buffer-name b))
           (rec (cmacs-brigade-undo-capture-kill-buffer name)))
      (kill-buffer b)
      (setq rec (cmacs-brigade-undo-tests--cycle rec t))
      (cmacs-brigade-undo-tests--undo rec)
      (with-current-buffer name
        (should (equal (buffer-string) "unsaved words"))
        (should (eq major-mode 'text-mode))
        (should (= (point) 3)))
      (kill-buffer name))))

(ert-deftest cmacs-brigade-undo-test-capture-windows-and-switch ()
  "Window tools put the layout back; switch_to_buffer kills what it made."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (save-window-excursion
    (delete-other-windows)
    (let ((rec (cmacs-brigade-undo-capture-windows)))
      (split-window)
      (setq rec (cmacs-brigade-undo-tests--cycle rec t))
      (cmacs-brigade-undo-tests--undo rec)
      (should (= (length (window-list)) 1)))
    (let* ((name (generate-new-buffer-name "undo-switch"))
           (rec (cmacs-brigade-undo-capture-switch-to-buffer name)))
      (switch-to-buffer name)
      (setq rec (cmacs-brigade-undo-tests--cycle rec name))
      (cmacs-brigade-undo-tests--undo rec)
      (should-not (get-buffer name)))))

(ert-deftest cmacs-brigade-undo-test-capture-goto-line ()
  "goto_line's inverse moves point back unless it moved again."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (goto-char 2)
    (let ((rec (cmacs-brigade-undo-capture-goto-line (current-buffer) 3)))
      (goto-char (point-max))
      (setq rec (cmacs-brigade-undo-tests--cycle rec t))
      (cmacs-brigade-undo-tests--undo rec)
      (should (= (point) 2)))))

(ert-deftest cmacs-brigade-undo-test-capture-save-and-find-file ()
  "save_buffer puts the file back and leaves the buffer modified;
find_file kills the buffer it opened."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let* ((dir (make-temp-file "undo-save" t))
         (file (expand-file-name "s.txt" dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "disk"))
          (let ((b (find-file-noselect file)))
            (with-current-buffer b
              (erase-buffer) (insert "agent text")
              (let ((rec (cmacs-brigade-undo-capture-save-buffer b)))
                (let ((inhibit-message t) (require-final-newline nil))
                  (save-buffer))
                (setq rec (cmacs-brigade-undo-tests--cycle rec t))
                (cmacs-brigade-undo-tests--undo rec)
                (should (equal (with-temp-buffer (insert-file-contents file)
                                                 (buffer-string))
                               "disk"))
                (should (equal (buffer-string) "agent text"))
                (should (buffer-modified-p))
                (set-buffer-modified-p nil)))
            (kill-buffer b))
          (save-window-excursion
            (let ((rec (cmacs-brigade-undo-capture-find-file file)))
              (find-file file)
              (setq rec (cmacs-brigade-undo-tests--cycle rec file))
              (cmacs-brigade-undo-tests--undo rec)
              (should-not (find-buffer-visiting file)))))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-undo-test-capture-gowl ()
  "The gowl captures restore focus, geometry, layout, workspace, transform;
spawn closes the spawned windows."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let* ((clients (list (list (cons 'id 1) (cons 'geometry '(0 0 100 100))
                              (cons 'floating t))
                        (list (cons 'id 2) (cons 'geometry '(5 5 50 50))
                              (cons 'floating nil))))
         (focused 1) (layout "[]=") (workspace 1) (transform 0)
         (closed nil)
         (find (lambda (id) (cl-find id clients
                                     :key (lambda (c) (alist-get 'id c))))))
    (cl-letf* (((symbol-function 'gowl-list-clients)
                (lambda (&rest _) (mapcar (lambda (c) (alist-get 'id c))
                                          clients)))
               ((symbol-function 'gowl-client-info)
                (lambda (c &rest _) (funcall find c)))
               ((symbol-function 'gowl-client-pid) (lambda (c &rest _) (* c 100)))
               ((symbol-function 'gowl-focused-client) (lambda (&rest _) focused))
               ((symbol-function 'gowl-focus-client)
                (lambda (c &rest _) (setq focused c)))
               ((symbol-function 'gowl-close-client)
                (lambda (c &rest _) (push c closed)))
               ((symbol-function 'gowl-client-set-geometry)
                (lambda (c x y w h &rest _)
                  (setcdr (assq 'geometry (funcall find c)) (list x y w h))))
               ((symbol-function 'gowl-set-client-floating)
                (lambda (c f &rest _)
                  (setcdr (assq 'floating (funcall find c)) f)))
               ((symbol-function 'cmacs-gowl-tools--find-or-signal)
                (lambda (pattern &rest _) (string-to-number pattern)))
               ;; The tile layout puts window 2 back where it tiles.
               ((symbol-function 'gowl-arrange)
                (lambda (&rest _)
                  (unless (alist-get 'floating (funcall find 2))
                    (setcdr (assq 'geometry (funcall find 2))
                            (list 5 5 50 50)))))
               ((symbol-function 'gowl-get-layout) (lambda (&rest _) layout))
               ((symbol-function 'gowl-set-layout)
                (lambda (name &rest _)
                  (setq layout (car (rassoc name
                                            cmacs-brigade-undo-gowl-layout-names)))
                  t))
               ((symbol-function 'gowl-workspace-current)
                (lambda (&rest _) workspace))
               ((symbol-function 'gowl-workspace-switch)
                (lambda (id &rest _) (setq workspace id)))
               ((symbol-function 'gowl-list-monitors) (lambda (&rest _) '(m)))
               ((symbol-function 'gowl-monitor-info)
                (lambda (&rest _) (list (cons 'name "eDP-1")
                                        (cons 'transform transform))))
               ((symbol-function 'gowl-set-monitor-transform)
                (lambda (tr &rest _) (setq transform tr))))
      ;; focus
      (let ((rec (cmacs-brigade-undo-capture-gowl-focus "2" nil)))
        (setq focused 2)
        (setq rec (cmacs-brigade-undo-tests--cycle rec "\"focused\""))
        (cmacs-brigade-undo-tests--undo rec)
        (should (= focused 1)))
      ;; geometry of a floating window
      (let ((rec (cmacs-brigade-undo-capture-gowl-geometry "1" nil 10 10 20 20)))
        (gowl-client-set-geometry 1 10 10 20 20)
        (setq rec (cmacs-brigade-undo-tests--cycle rec t))
        ;; moved again by the user: refused
        (gowl-client-set-geometry 1 9 9 9 9)
        (should (string-match-p "moved or resized"
                                (cmacs-brigade-undo-tests--stale-p rec)))
        (gowl-client-set-geometry 1 10 10 20 20)
        (cmacs-brigade-undo-tests--undo rec)
        (should (equal (alist-get 'geometry (funcall find 1)) '(0 0 100 100))))
      ;; geometry of a tiled window: floated by the call, tiled again
      (let ((rec (cmacs-brigade-undo-capture-gowl-geometry "2" nil 1 1 2 2)))
        (gowl-set-client-floating 2 t)
        (gowl-client-set-geometry 2 1 1 2 2)
        (setq rec (cmacs-brigade-undo-tests--cycle rec t))
        ;; a re-arrange moving it is not the user: still undoable
        (gowl-client-set-geometry 2 9 9 9 9)
        (cmacs-brigade-undo-tests--undo rec)
        (should-not (alist-get 'floating (funcall find 2)))
        (should (equal (alist-get 'geometry (funcall find 2)) '(5 5 50 50))))
      ;; layout
      (let ((rec (cmacs-brigade-undo-capture-gowl-layout "monocle")))
        (setq layout "[M]")
        (setq rec (cmacs-brigade-undo-tests--cycle rec t))
        (cmacs-brigade-undo-tests--undo rec)
        (should (equal layout "[]=")))
      ;; workspace
      (let ((rec (cmacs-brigade-undo-capture-gowl-workspace 3)))
        (setq workspace 3)
        (setq rec (cmacs-brigade-undo-tests--cycle rec t))
        (cmacs-brigade-undo-tests--undo rec)
        (should (= workspace 1)))
      ;; transform
      (let ((rec (cmacs-brigade-undo-capture-gowl-transform "eDP-1" 1)))
        (setq transform 1)
        (setq rec (cmacs-brigade-undo-tests--cycle rec t))
        (cmacs-brigade-undo-tests--undo rec)
        (should (= transform 0)))
      ;; spawn: pid 200 is client 2's
      (let ((rec (cmacs-brigade-undo-capture-gowl-spawn "foot")))
        (setq rec (cmacs-brigade-undo-tests--cycle rec "200"))
        (cmacs-brigade-undo-tests--undo rec)
        (should (equal closed '(2))))
      ;; spawn whose process has no window: refused, precisely
      (let ((rec (cmacs-brigade-undo-tests--cycle
                  (cmacs-brigade-undo-capture-gowl-spawn "foot") "999")))
        (should-error (funcall (plist-get rec :inverse) rec)
                      :type 'cmacs-brigade-undo-stale))
      ;; a closed window cannot have its geometry put back
      (let ((rec (cmacs-brigade-undo-tests--cycle
                  (cmacs-brigade-undo-capture-gowl-geometry "1" nil 3 3 3 3) t)))
        (setq clients (cdr clients))
        (should (string-match-p "window 1 was closed"
                                (cmacs-brigade-undo-tests--stale-p rec)))))))

(ert-deftest cmacs-brigade-undo-test-capture-context-switch ()
  "context_switch's inverse switches back, approved."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let ((current "home") (approved nil))
    (cl-letf (((symbol-function 'cmacs-context-current)
               (lambda (&rest _) current))
              ((symbol-function 'cmacs-context-switch)
               (lambda (name &rest _)
                 (setq approved cmacs-context--approved current name))))
      (cl-progv '(features) (list (cons 'cmacs-context features))
        (let ((rec (cmacs-brigade-undo-capture-context-switch "work")))
          (setq current "work")
          (setq rec (cmacs-brigade-undo-tests--cycle rec t))
          (cmacs-brigade-undo-tests--undo rec)
          (should (equal current "home"))
          (should approved))))))

(ert-deftest cmacs-brigade-undo-test-capture-screensaver ()
  "Wallpaper set/stop, pause/resume and fps put the previous state back."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let ((active nil) (name nil) (paused nil) (fps 30)
        (cmacs-brigade-undo--wallpaper nil))
    (cl-letf (((symbol-function 'cmacs-screensaver--wallpaper-active-p)
               (lambda (&rest _) active))
              ((symbol-function 'cmacs-screensaver-set-wallpaper)
               (lambda (n &rest _) (setq active t name n)))
              ((symbol-function 'cmacs-screensaver-stop-wallpaper)
               (lambda (&rest _) (setq active nil name nil)))
              ((symbol-function 'cmacs-screensaver-status)
               (lambda (&rest _) (list :paused paused :fps fps)))
              ((symbol-function 'cmacs-screensaver-pause)
               (lambda (&rest _) (setq paused t)))
              ((symbol-function 'cmacs-screensaver-resume)
               (lambda (&rest _) (setq paused nil)))
              ((symbol-function 'cmacs-screensaver-set-fps)
               (lambda (f &rest _) (setq fps f))))
      (cl-progv '(features) (list (cons 'cmacs-screensaver features))
        ;; set from nothing: undo stops it
        (let ((rec (cmacs-brigade-undo-capture-wallpaper-set "nebula")))
          (cmacs-screensaver-set-wallpaper 'nebula)
          (setq rec (cmacs-brigade-undo-tests--cycle rec "t"))
          (should (eq cmacs-brigade-undo--wallpaper 'nebula))
          ;; set another: undo brings nebula back
          (let ((rec2 (cmacs-brigade-undo-capture-wallpaper-set "aurora")))
            (cmacs-screensaver-set-wallpaper 'aurora)
            (setq rec2 (cmacs-brigade-undo-tests--cycle rec2 "t"))
            (cmacs-brigade-undo-tests--undo rec2)
            (should (eq name 'nebula)))
          (cmacs-brigade-undo-tests--undo rec)
          (should-not active))
        ;; stop: undo starts the known one again
        (cmacs-screensaver-set-wallpaper 'nebula)
        (setq cmacs-brigade-undo--wallpaper 'nebula)
        (let ((rec (cmacs-brigade-undo-capture-wallpaper-stop)))
          (cmacs-screensaver-stop-wallpaper)
          (setq rec (cmacs-brigade-undo-tests--cycle rec "t"))
          (cmacs-brigade-undo-tests--undo rec)
          (should (eq name 'nebula)))
        ;; one running that no tool started: irreversible
        (setq cmacs-brigade-undo--wallpaper nil)
        (should (cmacs-brigade-undo--irreversible-p
                 (cmacs-brigade-undo-capture-wallpaper-stop)))
        ;; pause / resume / fps
        (let ((rec (cmacs-brigade-undo-capture-screensaver-pause)))
          (setq paused t)
          (cmacs-brigade-undo-tests--undo rec)
          (should-not paused))
        (setq paused t)
        (let ((rec (cmacs-brigade-undo-capture-screensaver-resume)))
          (setq paused nil)
          (cmacs-brigade-undo-tests--undo rec)
          (should paused))
        (let ((rec (cmacs-brigade-undo-capture-screensaver-fps 60)))
          (setq fps 60)
          (cmacs-brigade-undo-tests--undo rec)
          (should (= fps 30)))))))

(ert-deftest cmacs-brigade-undo-test-capture-gsurf ()
  "gsurf: open closes, navigate goes back, zoom and module are restored."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let ((view (generate-new-buffer "undo-gsurf"))
        (uri "https://a.example/") (zoom 1.0) (enabled t))
    (unwind-protect
        (cl-letf (((symbol-function 'cmacs-gsurf-tools--target)
                   (lambda (&rest _) view))
                  ((symbol-function 'cmacs-gsurf-get-uri) (lambda (&rest _) uri))
                  ((symbol-function 'cmacs-gsurf-load-uri)
                   (lambda (_b u &rest _) (setq uri u)))
                  ((symbol-function 'cmacs-gsurf-get-zoom) (lambda (&rest _) zoom))
                  ((symbol-function 'cmacs-gsurf-set-zoom)
                   (lambda (_b z &rest _) (setq zoom z)))
                  ((symbol-function 'cmacs-gsurf-modules-list)
                   (lambda (&rest _)
                     (json-serialize
                      (vector (list :name "adblock"
                                    :enabled (if enabled t :false))))))
                  ((symbol-function 'cmacs-gsurf-module-set-enabled)
                   (lambda (_n e &rest _) (setq enabled e) t)))
          (cl-progv '(features) (list (cons 'cmacs-gsurf-tools features))
            (let ((rec (cmacs-brigade-undo-capture-gsurf-navigate "b" nil)))
              (setq uri "https://b.example/")
              (setq rec (cmacs-brigade-undo-tests--cycle rec uri))
              (cmacs-brigade-undo-tests--undo rec)
              (should (equal uri "https://a.example/")))
            (let ((rec (cmacs-brigade-undo-capture-gsurf-zoom 2.0 nil)))
              (setq zoom 2.0)
              (setq rec (cmacs-brigade-undo-tests--cycle rec "2.0"))
              (cmacs-brigade-undo-tests--undo rec)
              (should (= zoom 1.0)))
            (let ((rec (cmacs-brigade-undo-capture-gsurf-module "adblock" nil)))
              (setq enabled nil)
              (cmacs-brigade-undo-tests--undo rec)
              (should (eq enabled t)))
            ;; Asking for the state it already has changes nothing.
            (should-not (cmacs-brigade-undo-capture-gsurf-module "adblock" t))
            (let* ((opened (generate-new-buffer "undo-gsurf-new"))
                   (rec (cmacs-brigade-undo-tests--cycle
                         (cmacs-brigade-undo-capture-gsurf-open "x")
                         (buffer-name opened))))
              (cmacs-brigade-undo-tests--undo rec)
              (should-not (buffer-live-p opened)))))
      (kill-buffer view))))

(ert-deftest cmacs-brigade-undo-test-capture-imgedit-podomation-files ()
  "imgedit steps, layer and undo; podomation start/stop; file tools."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let ((undos 0) (redos 0) (layers 2) (removed nil) (running nil))
    (cl-letf (((symbol-function 'cmacs-imgedit-undo)
               (lambda (&rest _) (cl-incf undos) t))
              ((symbol-function 'cmacs-imgedit-redo)
               (lambda (&rest _) (cl-incf redos) t))
              ((symbol-function 'cmacs-imgedit-n-layers) (lambda (&rest _) layers))
              ((symbol-function 'cmacs-imgedit-remove-layer)
               (lambda (_h i &rest _) (setq removed i) t))
              ((symbol-function 'cmacs-podomation-running-p)
               (lambda (&rest _) running))
              ((symbol-function 'cmacs-podomation-start)
               (lambda (&rest _) (setq running t)))
              ((symbol-function 'cmacs-podomation-stop)
               (lambda (&rest _) (setq running nil))))
      (cmacs-brigade-undo-tests--undo
       (cmacs-brigade-undo-capture-imgedit-edit 1 "rect" 0 0 1 1))
      (should (= undos 1))
      (let ((rec (cmacs-brigade-undo-tests--cycle
                  (cmacs-brigade-undo-capture-imgedit-add-layer 1 "x")
                  "layer 1")))
        (cmacs-brigade-undo-tests--undo rec)
        (should (= removed 1)))
      (cmacs-brigade-undo-tests--undo
       (cmacs-brigade-undo-tests--cycle
        (cmacs-brigade-undo-capture-imgedit-undo 1) "undone"))
      (should (= redos 1))
      ;; An empty undo stack undid nothing: nothing to take back.
      (should-not (funcall (plist-get (cmacs-brigade-undo-capture-imgedit-undo 1)
                                      :after)
                           nil "nothing"))
      (let ((rec (cmacs-brigade-undo-capture-podomation-control "start" nil nil)))
        (setq running t)
        (cmacs-brigade-undo-tests--undo rec)
        (should-not running))
      (should-not (cmacs-brigade-undo-capture-podomation-control
                   "stop" nil nil))
      (should (cmacs-brigade-undo--irreversible-p
               (cmacs-brigade-undo-capture-podomation-control "run" "p" nil)))))
  (let* ((dir (make-temp-file "undo-files" t))
         (file (expand-file-name "out.csv" dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "before"))
          (dolist (capture (list (lambda () (cmacs-brigade-undo-capture-db-export
                                             "c" "select 1" "csv" file))
                                 (lambda () (cmacs-brigade-undo-capture-imgedit-save
                                             1 file))))
            (let ((rec (funcall capture)))
              (with-temp-file file (insert "after"))
              (setq rec (cmacs-brigade-undo-tests--cycle rec t))
              (cmacs-brigade-undo-tests--undo rec)
              (should (equal (with-temp-buffer (insert-file-contents file)
                                               (buffer-string))
                             "before")))))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-undo-test-capture-project-write ()
  "project_write_file's capture resolves the path as the tool does."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (let* ((dir (file-name-as-directory (make-temp-file "undo-proj" t)))
         (file (expand-file-name "f" dir)))
    (unwind-protect
        (cl-letf (((symbol-function 'cmacs-project-tools--resolve)
                   (lambda (path &rest _) (cons dir (expand-file-name path dir)))))
          (cl-progv '(features) (list (cons 'cmacs-project-tools features))
            (with-temp-file file (insert "v1"))
            (let ((rec (cmacs-brigade-undo-capture-project-write "f" "v2")))
              (with-temp-file file (insert "v2"))
              (setq rec (cmacs-brigade-undo-tests--cycle rec t))
              (cmacs-brigade-undo-tests--undo rec)
              (should (equal (with-temp-buffer (insert-file-contents file)
                                               (buffer-string))
                             "v1")))))
      (delete-directory dir t))))


;;;; Registration and the decision table

(ert-deftest cmacs-brigade-undo-test-register-validates-undo ()
  "A malformed :undo is a definition error."
  (skip-unless (cmacs-brigade-undo-tests--available-p))
  (should-error (cmacs-brigade-register-tool
                 :name 'undo-test-bad :description "x" :handler #'ignore
                 :undo 42)
                :type 'cmacs-brigade-tool-error)
  (should-error (cmacs-brigade-register-tool
                 :name 'undo-test-bad :description "x" :handler #'ignore
                 :undo '(irreversible 7))
                :type 'cmacs-brigade-tool-error))

(ert-deftest cmacs-brigade-undo-test-deftool-undo-form ()
  "A :undo FORM becomes a function of the parameters, documented."
  (cmacs-brigade-undo-tests--with
    (let* ((tool (cmacs-brigade-registry-get 'tool 'undo-test-replace))
           (undo (cmacs-brigade-tool-undo tool)))
      (should (functionp undo))
      (should (string-prefix-p "Undo: (cmacs-brigade-undo-buffer-record"
                               (documentation undo t))))
    (should (eq (cmacs-brigade-tool-undo
                 (cmacs-brigade-registry-get 'tool 'undo-test-three))
                'cmacs-brigade-undo-capture-buffer-text))))

(ert-deftest cmacs-brigade-undo-test-every-destructive-tool-decided ()
  "Every destructive shipped tool has an undo decision."
  (skip-unless (and (cmacs-brigade-undo-tests--available-p)
                    (fboundp 'cmacs-capability-load-shipped)))
  (let* ((root cmacs-brigade-undo-tests--root)
         (failed (cmacs-capability-load-shipped
                  (expand-file-name "lisp/cmacs" root))))
    (skip-unless (null failed))
    (let ((undecided (cl-remove-if-not (lambda (row) (eq (nth 2 row) 'undecided))
                                       (cmacs-brigade-undo-decision-table))))
      (should (equal (mapcar #'car undecided) nil)))))

(ert-deftest cmacs-brigade-undo-test-doc-table-current ()
  "The generated table in the docs is what the registry says."
  (skip-unless (and (cmacs-brigade-undo-tests--available-p)
                    (fboundp 'cmacs-capability-load-shipped)))
  (let* ((root cmacs-brigade-undo-tests--root)
         (failed (cmacs-capability-load-shipped
                  (expand-file-name "lisp/cmacs" root))))
    (skip-unless (null failed))
    (pcase-dolist (`(,rel . ,render) cmacs-brigade-undo-doc-files)
      (let* ((old (with-temp-buffer
                    (insert-file-contents (expand-file-name rel root))
                    (buffer-string))))
        (should (equal (cmacs-brigade-undo--splice old (funcall render))
                       old))))))

(provide 'cmacs-brigade-undo-tests)

;;; cmacs-brigade-undo-tests.el ends here
