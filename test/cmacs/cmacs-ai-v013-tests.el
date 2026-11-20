;;; cmacs-ai-v013-tests.el --- What ai-glib 0.13 brought to cmacs-ai -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ai-glib 0.13 added four things cmacs-ai adopted together: the ACP
;; provider, the codex app-server transport, real error codes for usage
;; limits (with a machine-readable reset time), and AiSteerable -- words
;; into a running turn.  Nothing here talks to a model or starts an
;; agent: what is asserted is the wiring, which is where each of these
;; goes wrong.
;;
;;   - Providers.  cmacs keeps TWO symbol tables (symbol -> type, and
;;     symbol -> constructor), and a provider present in one and absent
;;     from the other works in a chat buffer and is "unknown" in
;;     `cmacs-ai-call'.  Both are exercised for `acp' and for a named
;;     agent.
;;   - The classifier.  A pure function of an error's code and text.
;;   - Steering.  The tri-state answer, and above all that
;;     `indeterminate' is never re-queued.
;;
;; Guarded with `fboundp' on the primitive each test needs, never on a
;; feature name: the tests of pure Elisp run against any build, and the
;; ones that need a new DEFUN skip on a binary built before it existed.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'subr-x)

(when (locate-library "cmacs-ai")
  (require 'cmacs-ai nil t))
(when (locate-library "cmacs-ai-harness")
  (require 'cmacs-ai-harness nil t))

(defvar cmacs-ai-acp-agents)
(defvar cmacs-ai-codex-transport)
(defvar cmacs-ai-openai-compatible-endpoints)
(defvar cmacs-ai-harness--handle)
(defvar cmacs-ai-harness--regions)
(defvar cmacs-ai-harness--steers)
(defvar cmacs-ai-harness--queued)

;; Everything below is reached only behind an `fboundp' or `featurep'
;; guard; these keep the byte compiler quiet about a library that is
;; loaded conditionally and DEFUNs an older binary does not have.
(declare-function cmacs-ai-providers "cmacs-ai-defuns.c")
(declare-function cmacs-ai-list-models "cmacs-ai-stream.c")
(declare-function cmacs-ai-client-new "cmacs-ai-client.c")
(declare-function cmacs-ai-client-free "cmacs-ai-client.c")
(declare-function cmacs-ai-client-cli-p "cmacs-ai-client.c")
(declare-function cmacs-ai-client-cli-option "cmacs-ai-client.c")
(declare-function cmacs-ai-error-classify "cmacs-ai-stream.c")
(declare-function cmacs-ai-session-limit-scan "cmacs-ai-stream.c")
(declare-function cmacs-ai-tools-new "cmacs-ai-tools.c")
(declare-function cmacs-ai-tools-free "cmacs-ai-tools.c")
(declare-function cmacs-ai-tools-steer "cmacs-ai-tools.c")
(declare-function cmacs-ai-error-sentence "cmacs-ai")
(declare-function cmacs-ai-error-payload-sentence "cmacs-ai")
(declare-function cmacs-ai-harness--draw-prompt "cmacs-ai-harness")
(declare-function cmacs-ai-harness--on-event "cmacs-ai-harness")
(declare-function cmacs-ai-harness--flush-queued "cmacs-ai-harness")
(declare-function cmacs-ai-harness--hide-limit-notice "cmacs-ai-harness")
(declare-function cmacs-ai-harness-send "cmacs-ai-harness")
(declare-function cmacs-ai-harness-kill "cmacs-ai-harness")
(declare-function cmacs-ai-harness-set-prompt "cmacs-ai-harness")
(declare-function cmacs-ai-harness-prompt-string "cmacs-ai-harness")

(defun cmacs-ai-v013-tests--acp-build-p ()
  "Non-nil when this binary's provider tables know `acp'.
`cmacs-ai-providers' exists in older builds too, so its presence says
nothing; the getter DEFUN arrived in the same change as ACP."
  (and (fboundp 'cmacs-ai-providers)
       (fboundp 'cmacs-ai-client-cli-option)
       (memq 'acp (cmacs-ai-providers))))

(defmacro cmacs-ai-v013-tests--with-client (var provider &rest body)
  "Run BODY with VAR bound to a client handle for PROVIDER, then free it."
  (declare (indent 2))
  `(let ((,var (cmacs-ai-client-new ,provider)))
     (unwind-protect (progn ,@body)
       (cmacs-ai-client-free ,var))))

;;;; Providers: acp, and a named agent ----------------------------------

(ert-deftest cmacs-ai-v013-acp-is-offered ()
  "`acp' is in the provider list every chooser reads."
  (skip-unless (cmacs-ai-v013-tests--acp-build-p))
  (should (memq 'acp (cmacs-ai-providers))))

(ert-deftest cmacs-ai-v013-acp-round-trips-both-tables ()
  "`acp' resolves in the type table AND in the constructor table.

`cmacs-ai-list-models' goes through the type table (it builds from an
AiProviderType); `cmacs-ai-client-new' goes through the constructor
table.  ACP's model list is the static `default', so neither starts an
agent."
  (skip-unless (cmacs-ai-v013-tests--acp-build-p))
  (should (equal (cmacs-ai-list-models 'acp) '("default")))
  (cmacs-ai-v013-tests--with-client h 'acp
    (should (cmacs-ai-client-cli-p h))
    ;; Bare `acp' is left to $AI_ACP_COMMAND: no command is pushed.
    (should-not (cmacs-ai-client-cli-option h "command"))))

(ert-deftest cmacs-ai-v013-named-acp-agent-round-trips ()
  "A name in `cmacs-ai-acp-agents' is a provider in both tables,
and takes its own command line and flags."
  (skip-unless (cmacs-ai-v013-tests--acp-build-p))
  (let ((cmacs-ai-acp-agents
         '((test-acp-a :command "agent-a acp --stdio"
                       :skip-permissions t :client-fs nil)
           (test-acp-b :command "agent-b --experimental-acp"))))
    (should (memq 'test-acp-a (cmacs-ai-providers)))
    (should (memq 'test-acp-b (cmacs-ai-providers)))
    ;; type table
    (should (equal (cmacs-ai-list-models 'test-acp-a) '("default")))
    ;; constructor table, and the settings that only an entry carries
    (cmacs-ai-v013-tests--with-client h 'test-acp-a
      (should (cmacs-ai-client-cli-p h))
      (should (equal (cmacs-ai-client-cli-option h "command")
                     "agent-a acp --stdio"))
      (should (eq t (cmacs-ai-client-cli-option h "skip-permissions")))
      (should-not (cmacs-ai-client-cli-option h "client-fs")))
    ;; Two agents are two differently configured clients, and a flag an
    ;; entry does not mention keeps the library's default: permissions
    ;; refused, file reads served.
    (cmacs-ai-v013-tests--with-client h 'test-acp-b
      (should (equal (cmacs-ai-client-cli-option h "command")
                     "agent-b --experimental-acp"))
      (should-not (cmacs-ai-client-cli-option h "skip-permissions"))
      (should (eq t (cmacs-ai-client-cli-option h "client-fs")))))
  ;; and it is gone again once the config no longer names it
  (should-not (memq 'test-acp-a (cmacs-ai-providers)))
  (should-error (cmacs-ai-client-new 'test-acp-a)))

(ert-deftest cmacs-ai-v013-endpoint-name-wins-over-acp-agent ()
  "A name in both alists stays the endpoint it was before ACP existed,
and is offered once."
  (skip-unless (cmacs-ai-v013-tests--acp-build-p))
  (let ((cmacs-ai-openai-compatible-endpoints
         '((test-both :base-url "http://127.0.0.1:9/v1" :model "m1")))
        (cmacs-ai-acp-agents '((test-both :command "nope"))))
    (should (= 1 (cl-count 'test-both (cmacs-ai-providers))))
    (cmacs-ai-v013-tests--with-client h 'test-both
      ;; An HTTP client, so not a CLI.
      (should-not (cmacs-ai-client-cli-p h)))))

(ert-deftest cmacs-ai-v013-acp-agents-defcustom-shape ()
  "The defcustom exists and defaults to no agents."
  (skip-unless (boundp 'cmacs-ai-acp-agents))
  (should (null (default-value 'cmacs-ai-acp-agents)))
  (should (get 'cmacs-ai-acp-agents 'custom-type)))

;;;; Codex transport -----------------------------------------------------

(ert-deftest cmacs-ai-v013-codex-transport-defaults-to-exec ()
  "`exec' is the default, in the defcustom and on the client."
  (skip-unless (boundp 'cmacs-ai-codex-transport))
  (should (eq 'exec (default-value 'cmacs-ai-codex-transport)))
  (skip-unless (fboundp 'cmacs-ai-client-cli-option))
  (let ((cmacs-ai-codex-transport 'exec))
    (cmacs-ai-v013-tests--with-client h 'codex-cli
      (should (equal (cmacs-ai-client-cli-option h "transport") "exec")))))

(ert-deftest cmacs-ai-v013-codex-transport-app-server-is-applied ()
  "`app-server' reaches the client, as a symbol or as a string,
and under the `codex' alias too."
  (skip-unless (and (boundp 'cmacs-ai-codex-transport)
                    (fboundp 'cmacs-ai-client-cli-option)))
  (dolist (value '(app-server "app-server"))
    (let ((cmacs-ai-codex-transport value))
      (dolist (sym '(codex-cli codex))
        (cmacs-ai-v013-tests--with-client h sym
          (should (equal (cmacs-ai-client-cli-option h "transport")
                         "app-server"))))))
  ;; A value that is neither is read as the default, not passed on.
  (let ((cmacs-ai-codex-transport 'telepathy))
    (cmacs-ai-v013-tests--with-client h 'codex-cli
      (should (equal (cmacs-ai-client-cli-option h "transport") "exec")))))

;;;; The error classifier (C, pure) ---------------------------------------

(defconst cmacs-ai-v013-tests--reset 1900000000
  "A reset time comfortably in the future, as a Unix timestamp.")

(ert-deftest cmacs-ai-v013-classify-session-limit ()
  "A session limit yields its kind, its reset, and text without the notice."
  (skip-unless (fboundp 'cmacs-ai-error-classify))
  (let ((r (cmacs-ai-error-classify
            'session-limit
            (format "the account's session usage limit is reached; it \
resets at 18:50 on Friday 20 November ai-glib-session-limit: reset=%d"
                    cmacs-ai-v013-tests--reset))))
    (should (eq 'session-limit (nth 0 r)))
    (should (= cmacs-ai-v013-tests--reset (nth 1 r)))
    (should (equal (nth 2 r)
                   "the account's session usage limit is reached; it \
resets at 18:50 on Friday 20 November"))))

(ert-deftest cmacs-ai-v013-classify-strips-a-notice-mid-sentence ()
  "The notice sits between two halves of a sentence; one space remains."
  (skip-unless (fboundp 'cmacs-ai-error-classify))
  (let ((r (cmacs-ai-error-classify
            'rate-limited
            (format "codex is rate limited ai-glib-session-limit: \
reset=%d (codex: slow down)" cmacs-ai-v013-tests--reset))))
    (should (eq 'rate-limited (nth 0 r)))
    (should (= cmacs-ai-v013-tests--reset (nth 1 r)))
    (should (equal (nth 2 r) "codex is rate limited (codex: slow down)"))
    (should-not (string-match-p "ai-glib-session-limit" (nth 2 r)))))

(ert-deftest cmacs-ai-v013-classify-the-other-kinds ()
  "A 429 without a time, a lapsed login and an empty balance."
  (skip-unless (fboundp 'cmacs-ai-error-classify))
  (should (equal (cmacs-ai-error-classify 'rate-limited "slow down")
                 '(rate-limited nil "slow down")))
  (should (equal (cmacs-ai-error-classify 'invalid-api-key "sign in again")
                 '(signed-out nil "sign in again")))
  (should (equal (cmacs-ai-error-classify 'insufficient-quota "no credit")
                 '(quota nil "no credit")))
  ;; as a string too
  (should (eq 'quota (car (cmacs-ai-error-classify "insufficient-quota"
                                                   "no credit")))))

(ert-deftest cmacs-ai-v013-classify-leaves-ordinary-errors-alone ()
  "Everything else has no kind, and its text is untouched."
  (skip-unless (fboundp 'cmacs-ai-error-classify))
  (should (equal (cmacs-ai-error-classify 'cli-execution "boom")
                 '(nil nil "boom")))
  (should (equal (cmacs-ai-error-classify 'network-error "no route")
                 '(nil nil "no route")))
  (should (equal (cmacs-ai-error-classify nil "some other domain")
                 '(nil nil "some other domain")))
  (should-error (cmacs-ai-error-classify 'no-such-code "x")))

(ert-deftest cmacs-ai-v013-classify-a-notice-survives-rewrapping ()
  "A notice under the wrong code, or outside ai-glib's domain, is still
a pause: a layer that re-wraps an error must not turn \"paused\" into
\"failed\"."
  (skip-unless (fboundp 'cmacs-ai-error-classify))
  (dolist (code '(cli-execution nil))
    (let ((r (cmacs-ai-error-classify
              code (format "tool loop: ai-glib-session-limit: reset=%d"
                           cmacs-ai-v013-tests--reset))))
      (should (eq 'session-limit (nth 0 r)))
      (should (= cmacs-ai-v013-tests--reset (nth 1 r)))
      (should (equal (nth 2 r) "tool loop:"))))
  ;; A bare marker is a notice with no known reset.
  (should (equal (cmacs-ai-error-classify nil "x ai-glib-session-limit: y")
                 '(session-limit nil "x y"))))

(ert-deftest cmacs-ai-v013-session-limit-scan ()
  "Scanning a worker's output: the notice, or a sentence WITH a reset."
  (skip-unless (fboundp 'cmacs-ai-session-limit-scan))
  (should (equal (cmacs-ai-session-limit-scan
                  (format "line one\nai-glib-session-limit: reset=%d\nmore"
                          cmacs-ai-v013-tests--reset))
                 (list 'session-limit cmacs-ai-v013-tests--reset)))
  ;; A CLI's own sentence, with a duration ai-glib can read.
  (let ((r (cmacs-ai-session-limit-scan
            "You've hit your usage limit.  Try again in 2h 5m.")))
    (should (eq 'session-limit (car r)))
    (should (> (cadr r) (float-time))))
  ;; Prose that mentions a limit and states no reset parks nothing.
  (should-not (cmacs-ai-session-limit-scan
               "I checked the usage limit documentation for you."))
  (should-not (cmacs-ai-session-limit-scan "all tests passed")))

;;;; The sentence a person reads (Elisp, pure) ----------------------------

(ert-deftest cmacs-ai-v013-sentence-session-limit-names-the-reset ()
  "\"Session limit reached; resets 14:30\" -- a clock time the same day,
a date as well on any other."
  (skip-unless (fboundp 'cmacs-ai-error-sentence))
  (let* ((now (encode-time '(0 0 9 20 11 2026 nil -1 nil)))
         (today (float-time (encode-time '(0 30 14 20 11 2026 nil -1 nil))))
         (tomorrow (float-time (encode-time '(0 0 9 21 11 2026 nil -1 nil)))))
    (should (equal (cmacs-ai-error-sentence "" 'session-limit today now)
                   "Session limit reached; resets 14:30."))
    (should (string-match-p
             "\\`Session limit reached; resets 09:00 on [A-Za-z]+ 21 "
             (cmacs-ai-error-sentence "" 'session-limit tomorrow now)))
    ;; The provider's own words follow: the plan name is in them.
    (should (equal (cmacs-ai-error-sentence "claude: Max plan"
                                            'session-limit today now)
                   "Session limit reached; resets 14:30.  (claude: Max plan)"))
    ;; No reset known is said, not papered over.
    (should (string-match-p "did not say when"
                            (cmacs-ai-error-sentence "" 'session-limit nil)))))

(ert-deftest cmacs-ai-v013-sentence-each-kind-is-distinct ()
  "Four conditions, four different leads."
  (skip-unless (fboundp 'cmacs-ai-error-sentence))
  (let ((leads (mapcar (lambda (k) (cmacs-ai-error-sentence "" k nil))
                       '(session-limit rate-limited signed-out quota))))
    (should (= 4 (length (delete-dups (copy-sequence leads)))))
    (should (string-match-p "Rate limited" (nth 1 leads)))
    (should (string-match-p "[Ss]ign in" (nth 2 leads)))
    (should (string-match-p "quota" (nth 3 leads)))))

(ert-deftest cmacs-ai-v013-sentence-unclassified-is-unchanged ()
  "An ordinary error is shown exactly as the provider wrote it."
  (skip-unless (fboundp 'cmacs-ai-error-sentence))
  (should (equal (cmacs-ai-error-sentence "HTTP 500: boom") "HTTP 500: boom"))
  (should (equal (cmacs-ai-error-payload-sentence '(:error "HTTP 500: boom"))
                 "HTTP 500: boom")))

(ert-deftest cmacs-ai-v013-sentence-redirect-suggests-the-url ()
  "ai-glib 0.13 refuses a redirect that would carry the key elsewhere;
the message says to fix the URL, which is the only remedy."
  (skip-unless (fboundp 'cmacs-ai-error-sentence))
  (let ((s (cmacs-ai-error-sentence
            "Redirect refused (HTTP 301): a request that carries ...")))
    (should (string-prefix-p "Redirect refused (HTTP 301)" s))
    (should (string-match-p "base URL" s))
    (should (string-match-p ":base-url" s))))

(ert-deftest cmacs-ai-v013-payload-sentence-reads-the-extension ()
  "(:error MESSAGE :kind K :reset R) -- MESSAGE still second, so every
older reader of `cadr' is unaffected."
  (skip-unless (fboundp 'cmacs-ai-error-payload-sentence))
  (let ((payload (list :error "codex: Plus plan" :kind 'rate-limited
                       :reset nil)))
    (should (equal (cadr payload) "codex: Plus plan"))
    (should (equal (plist-get payload :error) "codex: Plus plan"))
    (should (string-match-p "\\`Rate limited; .*(codex: Plus plan)\\'"
                            (cmacs-ai-error-payload-sentence payload)))))

;;;; Steering in the harness buffer (stubs) --------------------------------

(defmacro cmacs-ai-v013-tests--with-harness-buffer (&rest body)
  "Run BODY in a buffer shaped like a harness buffer, with no harness.

The C entry points are stubbed, with `&rest' argument lists because a
stub of a C DEFUN that names its arguments fails under `make
check-cmacs' when the real arity differs.  `busy' and `sent' are the
session's pretend state; `steer-answer' is what `cmacs-ai-harness-steer'
returns."
  (declare (indent 0))
  `(with-temp-buffer
     (let ((busy t) (sent nil) (steer-answer 7) (steered nil))
       (ignore busy sent steer-answer steered)
       (cl-letf (((symbol-function 'cmacs-ai-harness-busy-p)
                  (lambda (&rest _) busy))
                 ((symbol-function 'cmacs-ai-harness-send-input)
                  (lambda (&rest args) (push (cadr args) sent) t))
                 ((symbol-function 'cmacs-ai-harness-steer)
                  (lambda (&rest args)
                    (push (cadr args) steered)
                    steer-answer)))
         (setq cmacs-ai-harness--handle 1)
         (setq cmacs-ai-harness--regions (make-hash-table))
         (cmacs-ai-harness--draw-prompt)
         ,@body))))

(defun cmacs-ai-v013-tests--harness-p ()
  (and (featurep 'cmacs-ai-harness)
       (fboundp 'cmacs-ai-harness--on-steer)
       (fboundp 'cmacs-ai-harness--send-while-busy)))

(ert-deftest cmacs-ai-v013-harness-send-while-busy-steers ()
  "A line typed mid-turn is steered, and remembered by its ticket."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (cmacs-ai-harness-set-prompt "use the staging db")
    (cmacs-ai-harness-send)
    (should (equal steered '("use the staging db")))
    (should (equal cmacs-ai-harness--steers '((7 . "use the staging db"))))
    ;; Not started as a turn, not queued, and the prompt is free again.
    (should-not sent)
    (should-not cmacs-ai-harness--queued)
    (should (equal (cmacs-ai-harness-prompt-string) ""))))

(ert-deftest cmacs-ai-v013-harness-delivered-marks-the-transcript ()
  "`delivered' leaves a small note and queues nothing."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (setq cmacs-ai-harness--steers '((7 . "use the staging db")))
    (cmacs-ai-harness--on-event (current-buffer)
                                '(:steer delivered nil 7))
    (should-not cmacs-ai-harness--steers)
    (should-not cmacs-ai-harness--queued)
    (should (string-match-p "steered: use the staging db" (buffer-string)))
    ;; The note belongs to the transcript: it cannot be typed into.
    (goto-char (point-min))
    (search-forward "steered")
    (should-error (insert "x") :type 'text-read-only)))

(ert-deftest cmacs-ai-v013-harness-indeterminate-is-never-requeued ()
  "`indeterminate' means sent-but-unconfirmed.  The words may already be
running, so queueing them for the next turn would run them twice."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (setq cmacs-ai-harness--steers '((7 . "do the thing")))
    (cmacs-ai-harness--on-event (current-buffer)
                                '(:steer indeterminate "the run ended" 7))
    (should-not cmacs-ai-harness--queued)
    (should-not sent)
    (should (string-match-p "unconfirmed" (buffer-string)))))

(ert-deftest cmacs-ai-v013-harness-refused-queues-for-the-next-turn ()
  "`refused' is provably not delivered: the words wait, then go as a turn."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (setq cmacs-ai-harness--steers '((7 . "do the thing")))
    (cmacs-ai-harness--on-event (current-buffer)
                                '(:steer refused "not steerable now" 7))
    (should (equal cmacs-ai-harness--queued '("do the thing")))
    (should-not sent)
    (should-not (string-match-p "steered" (buffer-string)))
    ;; Still busy: nothing goes.
    (cmacs-ai-harness--flush-queued (current-buffer))
    (should-not sent)
    ;; Idle: it goes, as an ordinary turn, and the queue is empty.
    (setq busy nil)
    (cmacs-ai-harness--flush-queued (current-buffer))
    (should (equal sent '("do the thing")))
    (should-not cmacs-ai-harness--queued)))

(ert-deftest cmacs-ai-v013-harness-answers-match-by-ticket ()
  "Two steers in flight, answered out of order, each settle their own."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (setq cmacs-ai-harness--steers '((8 . "second") (7 . "first")))
    (cmacs-ai-harness--on-event (current-buffer) '(:steer refused nil 8))
    (should (equal cmacs-ai-harness--queued '("second")))
    (should (equal cmacs-ai-harness--steers '((7 . "first"))))
    (cmacs-ai-harness--on-event (current-buffer) '(:steer delivered nil 7))
    (should (equal cmacs-ai-harness--queued '("second")))
    (should (string-match-p "steered: first" (buffer-string)))))

(ert-deftest cmacs-ai-v013-harness-unsteerable-engine-queues ()
  "An engine with no seam returns nil from the steer; the line is queued."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (setq steer-answer nil)
    (cmacs-ai-harness-set-prompt "later then")
    (cmacs-ai-harness-send)
    (should-not cmacs-ai-harness--steers)
    (should (equal cmacs-ai-harness--queued '("later then")))))

(ert-deftest cmacs-ai-v013-harness-slash-command-is-not-steered ()
  "Steering sends text as written, so a command typed mid-turn stays put."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (cmacs-ai-harness-set-prompt "/clear")
    (cmacs-ai-harness-send)
    (should-not steered)
    (should-not cmacs-ai-harness--queued)
    (should (equal (cmacs-ai-harness-prompt-string) "/clear"))))

(ert-deftest cmacs-ai-v013-harness-cancel-hands-queued-lines-back ()
  "Stopping a turn must not be answered by starting the queued one."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (cl-letf (((symbol-function 'cmacs-ai-harness-cancel)
               (lambda (&rest _) (setq busy nil) t)))
      (setq cmacs-ai-harness--queued '("one" "two"))
      (cmacs-ai-harness-kill)
      (should-not cmacs-ai-harness--queued)
      (should (equal (cmacs-ai-harness-prompt-string) "one\ntwo"))
      (cmacs-ai-harness--flush-queued (current-buffer))
      (should-not sent))))

(ert-deftest cmacs-ai-v013-harness-error-event-tolerates-the-extension ()
  "The :error handler matches the two-element payload and the longer one,
and a classified error is written where it can be scrolled back to."
  (skip-unless (cmacs-ai-v013-tests--harness-p))
  (cmacs-ai-v013-tests--with-harness-buffer
    (let ((inhibit-message t))
      (cmacs-ai-harness--on-event (current-buffer) '(:error "plain failure"))
      (should-not (string-match-p "plain failure" (buffer-string)))
      (cmacs-ai-harness--on-event
       (current-buffer)
       (list :error "claude: Max plan" :kind 'session-limit :reset nil))
      (should (string-match-p "Session limit reached" (buffer-string))))))

(ert-deftest cmacs-ai-v013-harness-hides-the-raw-notice ()
  "ai-glib's own error block carries the notice; a person does not read it."
  (skip-unless (and (featurep 'cmacs-ai-harness)
                    (fboundp 'cmacs-ai-harness--hide-limit-notice)))
  (with-temp-buffer
    (insert "it resets at 18:50 ai-glib-session-limit: reset=1900000000 (x)")
    (cmacs-ai-harness--hide-limit-notice (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "ai-glib-session-limit")
    (should (equal "" (get-text-property (match-beginning 0) 'display)))
    ;; Nothing was deleted: the library's spans are byte offsets.
    (should (string-match-p "reset=1900000000" (buffer-string)))
    ;; and the words either side are untouched
    (should-not (get-text-property (point-min) 'display))
    (should-not (get-text-property (1- (point-max)) 'display))))

;;;; Steering from C: the real primitives ---------------------------------

(ert-deftest cmacs-ai-v013-tools-steer-with-no-run-is-refused ()
  "Steering an executor that is running nothing answers `refused', on
the main thread, with the ticket the call returned.

This is the one steer that needs no model: ai-glib refuses it without a
turn to deliver into.  It exercises the whole return path -- the async
answer, the hop to the cmacs context, the callback."
  (skip-unless (and (fboundp 'cmacs-ai-tools-steer)
                    (fboundp 'cmacs-ai-tools-new)))
  (let* ((exec (cmacs-ai-tools-new))
         (answer nil)
         (ticket nil))
    (unwind-protect
        (progn
          (setq ticket (cmacs-ai-tools-steer
                        exec "hello" (lambda (payload) (setq answer payload))))
          (should (integerp ticket))
          (with-timeout (10 nil)
            (while (null answer)
              (accept-process-output nil 0.05)))
          (should answer)
          (should (eq :steer (nth 0 answer)))
          (should (eq 'refused (nth 1 answer)))
          (should (or (null (nth 2 answer)) (stringp (nth 2 answer))))
          (should (eql ticket (nth 3 answer))))
      (cmacs-ai-tools-free exec)))
  (should-error (cmacs-ai-tools-steer 999999 "x" #'ignore)))

(ert-deftest cmacs-ai-v013-harness-steerable-defcustom ()
  "On by default: a real claude is unaffected by an open stdin."
  (skip-unless (boundp 'cmacs-ai-harness-steerable))
  (should (eq t (default-value 'cmacs-ai-harness-steerable))))

(provide 'cmacs-ai-v013-tests)

;;; cmacs-ai-v013-tests.el ends here
