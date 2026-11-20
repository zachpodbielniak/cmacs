;;; cmacs-clawtilla-parity-tests.el --- The 0.52 half of the clawtilla client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What clawtilla 0.52 added to this client: the daemon's notification
;; list and read marks, tasks and projects, a conversation's files,
;; devices and pairing, the pushed events, and the list pages.
;;
;; Three kinds of test, and which runs where matters:
;;
;; - Pure Elisp: payloads, drawing from a canned reply, the page
;;   framework.  These stub `cmacs-clawtilla--ask' (with &rest: a stub
;;   of a C DEFUN must take whatever arity the caller uses) so they run
;;   in a build whose C side predates the primitive.
;; - Source guards: every question the Elisp asks is one the C table
;;   answers, every pushed event the brief names is in the event table.
;;   They read the sources, so they hold even with nothing compiled.
;; - The library's answers: gated on `(fboundp 'cmacs-clawtilla--ask)',
;;   the primitive itself, never on a feature name.

;;; Code:

(require 'cmacs nil t)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; At compile time as well as at load: the suite uses the client's
;; struct accessors as `setf' places and its macros, and a compiler that
;; has not seen their definitions compiles `(setf (accessor x) v)' into a
;; call to a function that does not exist.
(eval-and-compile
  (defun cmacs-clawtilla-parity-tests--available-p ()
    "Non-nil when this build compiled in the clawtilla client."
    (and (boundp 'is-cmacs-clawtilla) (symbol-value 'is-cmacs-clawtilla)
         (fboundp 'cmacs-clawtilla-supported-p)))

  (when (cmacs-clawtilla-parity-tests--available-p)
    (require 'cmacs-clawtilla)
    (require 'cmacs-clawtilla-init nil t)))

;; Special in the client, and declared so here too: this file requires
;; the client only when it was compiled in, so without these a compiled
;; copy of the suite would bind them lexically -- and every `let' below
;; would rebind nothing the code under test can see.
(defvar cmacs-clawtilla--labels)
(defvar cmacs-clawtilla--viewing-room)
(defvar cmacs-clawtilla-alerts--agent)
(defvar cmacs-clawtilla-events-table)
(defvar cmacs-clawtilla-image-progress)
(defvar cmacs-clawtilla-known-rooms-function)
(defvar cmacs-clawtilla-page--data)
(defvar cmacs-clawtilla-page--loaded)
(defvar cmacs-clawtilla-page--name)
(defvar cmacs-clawtilla-page-mode-map)
(defvar cmacs-clawtilla-page-verb-keys)
(defvar cmacs-clawtilla-pages)
(defvar cmacs-clawtilla-section--page)
(defvar cmacs-clawtilla-section--reply)
(defvar cmacs-clawtilla-section--rows)
(defvar cmacs-clawtilla-section-routine-text-fields)
(defvar cmacs-clawtilla-tasks--state-cache)
(defvar cmacs-clawtilla-unread)
(defvar cmacs-clawtilla-unread-changed-hook)

(defvar cmacs-clawtilla-parity-tests--asked nil
  "What the stubbed `cmacs-clawtilla--ask' was asked: (WHAT . ARGS-JSON).")

(defvar cmacs-clawtilla-parity-tests--answers nil
  "What the stubbed `cmacs-clawtilla--ask' answers: question to answer.")

(defmacro cmacs-clawtilla-parity-tests--with-asks (answers &rest body)
  "Run BODY with `cmacs-clawtilla--ask' answering from ANSWERS.

ANSWERS is an alist of question to answer; a question not listed is
answered nil.  Every question asked is recorded."
  (declare (indent 1) (debug t))
  `(let ((cmacs-clawtilla-parity-tests--asked nil)
         (cmacs-clawtilla-parity-tests--answers ,answers)
         (cmacs-clawtilla--labels nil))
     (cl-letf (((symbol-function 'cmacs-clawtilla--ask)
                (lambda (&rest args)
                  (push (cons (nth 0 args) (nth 1 args))
                        cmacs-clawtilla-parity-tests--asked)
                  (cdr (assoc (nth 0 args)
                              cmacs-clawtilla-parity-tests--answers)))))
       ,@body)))

(defun cmacs-clawtilla-parity-tests--source (name)
  "Return the text of the client source file NAME, or nil."
  (let* ((library (locate-library "cmacs-clawtilla"))
         (file (and library
                    (expand-file-name
                     name (file-name-directory library)))))
    (when (and file (file-exists-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))


;;;; Asking the library.

(ert-deftest cmacs-clawtilla-parity-ask-splices-raw-json ()
  "A value the daemon sent travels as the text it sent, not re-encoded.

The reason is on record in this client: a null re-encoded from the
ordinary parse is an empty object, which the library reads as a value."
  (skip-unless (cmacs-clawtilla-parity-tests--available-p))
  (cmacs-clawtilla-parity-tests--with-asks nil
    (cmacs-clawtilla-ask "anything" :reply (cons :json "{\"team\":null}")
                         :n 3 :on t :off :false :none nil :text "a\"b")
    (let ((sent (cdr (car cmacs-clawtilla-parity-tests--asked))))
      (should (string-match-p "\"reply\":{\"team\":null}" sent))
      (should (string-match-p "\"n\":3" sent))
      (should (string-match-p "\"on\":true" sent))
      (should (string-match-p "\"off\":false" sent))
      (should (string-match-p "\"none\":null" sent))
      ;; And it is one JSON object, whatever was in the strings.
      (should (equal "a\"b" (alist-get 'text (cmacs-clawtilla--parse sent)))))))

(ert-deftest cmacs-clawtilla-parity-faithful-keeps-null-and-false ()
  "The faithful parse round-trips null, false and an empty array."
  (skip-unless (cmacs-clawtilla-parity-tests--available-p))
  (let* ((text "{\"a\":null,\"b\":false,\"c\":[],\"d\":[{\"x\":1}]}")
         (parsed (cmacs-clawtilla-faithful text)))
    (should (equal text (cmacs-clawtilla-faithful-text parsed)))
    (should (equal "{\"x\":1}"
                   (cmacs-clawtilla-faithful-text
                    (cmacs-clawtilla-faithful-get parsed 'd 0))))
    (should (null (cmacs-clawtilla-faithful-text
                   (cmacs-clawtilla-faithful-get parsed 'a))))))

(ert-deftest cmacs-clawtilla-parity-every-question-has-an-answer ()
  "Every question the Elisp asks is in the C table that answers them.

A question the table does not know is answered nil, which every caller
treats as \"the library had nothing to say\" -- so a misspelt name does
not fail, it quietly draws less.  Checked against the sources."
  (skip-unless (cmacs-clawtilla-parity-tests--available-p))
  (let* ((library (locate-library "cmacs-clawtilla"))
         (dir (and library (file-name-directory library)))
         (render (and dir (expand-file-name
                           "../../cmacs/clawtilla/cmacs-clawtilla-render.c"
                           dir)))
         (known nil)
         (unknown nil))
    (skip-unless (and render (file-exists-p render)))
    (with-temp-buffer
      (insert-file-contents render)
      (goto-char (point-min))
      (while (re-search-forward "^  { \"\\([a-z-]+\\)\", +ask_[a-z_]+ }" nil t)
        (push (match-string 1) known)))
    (should (> (length known) 40))
    (dolist (file (directory-files dir t "\\`cmacs-clawtilla.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                "(cmacs-clawtilla-ask\\(?:-parsed\\)?[ \n]+\"\\([a-z-]+\\)\""
                nil t)
          (unless (member (match-string 1) known)
            (push (format "%s asks %s" (file-name-nondirectory file)
                          (match-string 1))
                  unknown)))))
    (should (null unknown))))

(ert-deftest cmacs-clawtilla-parity-the-library-answers ()
  "The answers are libclawt's, asked through the one primitive."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla--ask)))
  ;; An unknown question is nil, not an error.
  (should (null (cmacs-clawtilla-ask "no-such-question")))
  ;; The bell adds up what the reply carries and counts a missing member
  ;; as nothing rather than failing.
  (should (equal "0" (cmacs-clawtilla-ask "notice-badge"
                                          :reply (cons :json "{}"))))
  ;; A mute is read out of the list, as a set.
  (should (equal '("scout")
                 (cmacs-clawtilla-ask-parsed
                  "notice-mutes"
                  :reply (cons :json "{\"mutes\":[{\"agent\":\"scout\"}]}"))))
  ;; A daemon too old to hold read marks sends no counts: nil, and the
  ;; client goes on counting from events.
  (should (null (cmacs-clawtilla-ask
                 "unread-seed"
                 :rooms (cons :json "[{\"id\":\"dm:scout:user\"}]")
                 :rows ["dm:scout:user"])))
  ;; A muted agent's conversation leaves the total and keeps its row.
  (should (equal "2" (cmacs-clawtilla-ask
                      "unread-total"
                      :unread (cons :json "{\"dm:a:user\":2,\"dm:b:user\":5}")
                      :muted ["b"])))
  ;; The fixed labels arrive in one answer, every one a string.
  (let ((labels (cmacs-clawtilla-ask-parsed "message-labels")))
    (dolist (name '(steered interrupted ack crosstalk task_consult
                    decision_via_chat egress_allowlist))
      (should (stringp (alist-get name labels)))))
  ;; A pairing code is six digits however it was typed, and nothing
  ;; else is a code at all.
  (should (equal "123456" (cmacs-clawtilla-ask "device-code-normalize"
                                               :text "123 456")))
  (should (null (cmacs-clawtilla-ask "device-code-normalize" :text "12345")))
  ;; What a state means is asked, per state.
  (let ((state (cmacs-clawtilla-ask-parsed "task-state" :state "unassigned")))
    (should (stringp (alist-get 'tone state)))))

(ert-deftest cmacs-clawtilla-parity-new-choice-families-are-walked ()
  "The choice lists the GTK drop-downs use are offered, not typed."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla--ask)))
  (dolist (family '("effort" "weekday" "schedule" "resolution" "usage-group"
                    "ack-check-model" "review-by" "incident-recipient"
                    "steer-policy" "task-state"))
    (let ((values (cmacs-clawtilla--parse (cmacs-clawtilla--enum family))))
      (should values)
      (dolist (entry values)
        (should (stringp (alist-get 'nick entry)))))))


;;;; The page framework.

(ert-deftest cmacs-clawtilla-parity-a-page-draws-and-dispatches ()
  "A page draws its body from what its frames answered and runs its verbs."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-define-page)))
  (let ((ran nil)
        (cmacs-clawtilla-pages cmacs-clawtilla-pages))
    (cmacs-clawtilla-define-page "test-page"
      :title "A test"
      :intro "Said under the title."
      :draw (lambda ()
              (dolist (row (cmacs-clawtilla-page-data 'rows 'rows))
                (cmacs-clawtilla-page-insert-row
                 'test-row row (alist-get 'id row) "one\ntwo" nil "")))
      :verbs (list (list "x" "do it" (lambda () (interactive) (setq ran t)))))
    (with-temp-buffer
      (cmacs-clawtilla-page-mode)
      (setq cmacs-clawtilla-page--name "test-page")
      (setq cmacs-clawtilla-page--data
            (list (list 'rows '((rows ((id . "alpha")) ((id . "beta"))))
                        "{}" nil)))
      (setq cmacs-clawtilla-page--loaded t)
      (cmacs-clawtilla-page--draw)
      (should (string-match-p "A test" (buffer-string)))
      (should (string-match-p "Said under the title" (buffer-string)))
      (goto-char (point-min))
      (search-forward "beta")
      (should (equal "beta" (alist-get 'id (cmacs-clawtilla-page-row
                                            'test-row))))
      ;; The detail lines belong to their row.
      (forward-line 1)
      (should (equal "beta" (alist-get 'id (cmacs-clawtilla-page-row
                                            'test-row))))
      ;; The verb is found by its key, and a key the page did not give
      ;; says so rather than doing something.
      (should (cmacs-clawtilla-page--verb-for "x"))
      (should-not (cmacs-clawtilla-page--verb-for "D"))
      (funcall (nth 2 (cmacs-clawtilla-page--verb-for "x")))
      (should ran)
      ;; And the menu is built from the same list.
      (should (= 3 (length (cmacs-clawtilla-page--menu-children nil)))))))

(ert-deftest cmacs-clawtilla-parity-a-page-says-which-frame-failed ()
  "A frame that failed is said on the page, above whatever the rest drew."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-define-page)))
  (let ((cmacs-clawtilla-pages cmacs-clawtilla-pages))
    (cmacs-clawtilla-define-page "test-failing"
      :title "T" :draw (lambda () (insert "body\n")))
    (with-temp-buffer
      (cmacs-clawtilla-page-mode)
      (setq cmacs-clawtilla-page--name "test-failing")
      (setq cmacs-clawtilla-page--data
            (list (list 'rows nil nil "this daemon keeps no such thing")))
      (setq cmacs-clawtilla-page--loaded t)
      (cmacs-clawtilla-page--draw)
      (should (string-match-p "keeps no such thing" (buffer-string)))
      (should (string-match-p "body" (buffer-string))))))

(ert-deftest cmacs-clawtilla-parity-a-page-takes-no-motion-key ()
  "No verb key is a key an Evil user moves with."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (boundp 'cmacs-clawtilla-page-verb-keys)))
  (dolist (key '("j" "k" "h" "l" "w" "b" "e" "n" "N" "g" "G" "f" "F" "t" "T"
                 "H" "M" "L" "W" "B" "E" "0" "$" "/" ";" "SPC" ","))
    (should-not (member key cmacs-clawtilla-page-verb-keys)))
  ;; And every page stays inside the keys the one mode map dispatches.
  (dolist (page cmacs-clawtilla-pages)
    (dolist (verb (plist-get (cdr page) :verbs))
      (should (member (car verb) cmacs-clawtilla-page-verb-keys)))))

(ert-deftest cmacs-clawtilla-parity-payload-leaves-out-the-blank ()
  "A field left blank is absent from the frame, not sent empty."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-payload)))
  (should (equal '((prompt . "do it") (agent . "scout"))
                 (cmacs-clawtilla-payload :prompt "do it" :title ""
                                          :agent "scout" :after nil))))


;;;; Notifications and read marks.

(ert-deftest cmacs-clawtilla-parity-known-rooms-do-not-recurse ()
  "The fleet's room list calls the default, not itself.

`cmacs-clawtilla-known-rooms' calls whatever the function variable
holds, and the fleet set the variable to a function that called
`cmacs-clawtilla-known-rooms' -- unbounded recursion, swallowed inside
the event dispatch, so every unread count simply never rose."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-fleet--known-rooms)))
  (let ((cmacs-clawtilla-known-rooms-function
         #'cmacs-clawtilla-fleet--known-rooms)
        (max-lisp-eval-depth 400))
    (should (listp (cmacs-clawtilla-known-rooms)))))

(ert-deftest cmacs-clawtilla-parity-room-read-takes-the-daemons-number ()
  "A `room.read' event sets the count to the daemon's, and 0 clears it."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-alerts--apply-room-read)))
  (let ((cmacs-clawtilla-unread (make-hash-table :test 'equal))
        (cmacs-clawtilla--viewing-room nil)
        (cmacs-clawtilla-unread-changed-hook nil))
    (puthash "dm:scout:user" 7 cmacs-clawtilla-unread)
    (cmacs-clawtilla-alerts--apply-room-read "dm:scout:user" 2)
    (should (= 2 (cmacs-clawtilla-unread-count "dm:scout:user")))
    (cmacs-clawtilla-alerts--apply-room-read "dm:scout:user" 0)
    (should (= 0 (cmacs-clawtilla-unread-count "dm:scout:user")))
    ;; The room on screen is never counted, whatever the daemon says.
    (setq cmacs-clawtilla--viewing-room "dm:scout:user")
    (cmacs-clawtilla-alerts--apply-room-read "dm:scout:user" 4)
    (should (= 0 (cmacs-clawtilla-unread-count "dm:scout:user")))))

(ert-deftest cmacs-clawtilla-parity-the-list-draws-its-four-sections ()
  "The daemon's list is drawn as Chats, Decisions, Grok jobs and Alerts."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-alerts--draw)))
  (cmacs-clawtilla-parity-tests--with-asks
      '(("notice-badge" . "4") ("time-ago" . "3 minutes ago"))
    (let ((conn (cmacs-clawtilla--connection-create
                 :handle 0 :name "t" :state 'connected)))
      (setf (cmacs-clawtilla-connection-notices conn)
            (cmacs-clawtilla--parse
             "{\"unread\":1,
               \"chats\":[{\"agent\":\"scout\",\"room\":\"dm:scout:user\",\"unread\":3}],
               \"decisions\":[{\"agent\":\"scout\",\"question\":\"Ship it?\"}],
               \"grok\":[{\"id\":\"j1\",\"bot\":\"deploy\",\"state\":\"needs_input\",\"agent\":\"ops\"}],
               \"notices\":[{\"id\":9,\"title\":\"A run broke\",\"tier\":\"error\",
                             \"agent\":\"ops\",\"read\":false,\"created_at\":1,\"source\":\"routine\"}]}"))
      (setf (cmacs-clawtilla-connection-notices-json conn) "{}")
      (setf (cmacs-clawtilla-connection-muted conn) '("ops"))
      (with-temp-buffer
        (cmacs-clawtilla-alerts-mode)
        (setq-local cmacs-clawtilla-connection conn)
        (cmacs-clawtilla-alerts--draw)
        (let ((text (buffer-string)))
          (should (string-match-p "Chats (1)" text))
          (should (string-match-p "3 unread" text))
          (should (string-match-p "Decisions waiting (1)" text))
          (should (string-match-p "Ship it\\?" text))
          (should (string-match-p "Grok jobs needing attention (1)" text))
          (should (string-match-p "Alerts (1)" text))
          (should (string-match-p "A run broke" text))
          (should (string-match-p "muted: ops" text)))
        ;; Narrowed to one agent, the others' rows go.
        (setq cmacs-clawtilla-alerts--agent "ops")
        (cmacs-clawtilla-alerts--draw)
        (should-not (string-match-p "Ship it" (buffer-string)))
        (should (string-match-p "A run broke" (buffer-string)))))))


;;;; Tasks and projects.

(ert-deftest cmacs-clawtilla-parity-tasks-are-named-by-task ()
  "Every task frame names its task as `task'; the source says so.

`task.cancel' was sent with `id', which the daemon does not read: the
request was refused and nothing was cancelled from here."
  (skip-unless (cmacs-clawtilla-parity-tests--available-p))
  (let ((source (cmacs-clawtilla-parity-tests--source
                 "cmacs-clawtilla-tasks.el")))
    (skip-unless source)
    (dolist (kind '("task.cancel" "task.assign" "task.comment" "task.diff"
                    "task.checkout_remove" "task.link" "task.unlink"
                    "task.venture_retry"))
      (should (string-match-p
               (concat (regexp-quote (format "\"%s\"" kind))
                       "[^\"]*(cons 'task ")
               source)))))

(ert-deftest cmacs-clawtilla-parity-an-incident-says-where-it-stands ()
  "A broken run's line says who was told, how often, and who retried."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-tasks--incident-status)))
  (should (equal "Not reported yet"
                 (cmacs-clawtilla-tasks--incident-status nil)))
  (should (equal "Waiting for lead to finish a turn"
                 (cmacs-clawtilla-tasks--incident-status
                  '((recipient . "lead") (queued . t)))))
  (should (equal "Reported to lead · broke 3 times · last retried by you"
                 (cmacs-clawtilla-tasks--incident-status
                  '((recipient . "lead") (occurrences . 3)
                    (retried_by . "user"))))))

(ert-deftest cmacs-clawtilla-parity-the-tasks-page-draws ()
  "Broken runs come first, then every task with what it waits on."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-tasks--draw)))
  (require 'cmacs-clawtilla-section)
  (clrhash cmacs-clawtilla-tasks--state-cache)
  (cmacs-clawtilla-parity-tests--with-asks
      '(("task-state" . "{\"tone\":\"warn\",\"cancellable\":true,\"retryable\":false}")
        ("task-caption" . "Since yesterday")
        ("task-waiting" . "Waiting on t1")
        ("message-labels" . "{\"task_consult\":\"consult\"}"))
    (let ((text "{\"since\":1,\"kept\":true,\"retention_days\":30,\"tasks\":[
                  {\"id\":\"t2\",\"title\":\"Ship\",\"state\":\"blocked\",
                   \"origin\":\"user\",\"assignee\":null,
                   \"waiting_on\":[\"t1\"],\"consult\":true}]}"))
      (with-temp-buffer
        (cmacs-clawtilla-section-mode)
        (setq cmacs-clawtilla-section--page "tasks")
        (setq cmacs-clawtilla-section--reply
              (list (cons 'tasks (cmacs-clawtilla--parse text))
                    (cons 'tasks-text text)
                    (cons 'incidents
                          '((enabled . t) (to . "lead")
                            (incidents ((id . "i1") (agent . "ops")
                                        (kind . "failed")
                                        (kind_label . "failed")
                                        (retryable . t)))))))
        (setq cmacs-clawtilla-section--rows
              (alist-get 'tasks (alist-get 'tasks
                                           cmacs-clawtilla-section--reply)))
        (let ((inhibit-read-only t))
          (cmacs-clawtilla-tasks--draw))
        (let ((drawn (buffer-string)))
          (should (string-match-p "Since yesterday" drawn))
          (should (string-match-p "ops's run failed" drawn))
          (should (string-match-p "Ship" drawn))
          (should (string-match-p "user · on the backlog" drawn))
          (should (string-match-p "Waiting on t1" drawn))
          (should (string-match-p "consult" drawn)))
        ;; `waiting_on' went to the library as the daemon sent it.
        (should (string-match-p
                 "\"waiting_on\":\\[\"t1\"\\]"
                 (cdr (assoc "task-waiting"
                             cmacs-clawtilla-parity-tests--asked))))))
    (clrhash cmacs-clawtilla-tasks--state-cache)))

(ert-deftest cmacs-clawtilla-parity-a-project-field-reads-as-text ()
  "A project's fields are edited as text, whatever type they came as."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-projects--field-text)))
  (let ((project '((name . "Site") (agents "a" "b")
                   (monthly_budget_usd . 12.5) (budget_hard_stop . t))))
    (should (equal "Site" (cmacs-clawtilla-projects--field-text
                           project "name")))
    (should (equal "a, b" (cmacs-clawtilla-projects--field-text
                           project "agents")))
    (should (equal "12.5" (cmacs-clawtilla-projects--field-text
                           project "monthly_budget_usd")))
    (should (equal "true" (cmacs-clawtilla-projects--field-text
                           project "budget_hard_stop")))
    (should (equal "" (cmacs-clawtilla-projects--field-text
                       project "goal")))))


;;;; Routines.

(ert-deftest cmacs-clawtilla-parity-a-routine-says-instructions ()
  "A routine's work is `instructions', and its integers are integers.

The daemon reads a routine field by field from its own schema, and
`prompt' is not one of them: a routine added with it was saved with
nothing to do."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (require 'cmacs-clawtilla-section nil t)))
  (should (member "instructions"
                  cmacs-clawtilla-section-routine-text-fields))
  (should-not (member "prompt" cmacs-clawtilla-section-routine-text-fields))
  (let ((payload (cmacs-clawtilla-section--routine-payload
                  "nightly" '(("instructions" . "check")
                              ("max_start_failures" . "3")
                              ("catch_up" . nil)))))
    (should (equal "check" (alist-get 'instructions payload)))
    (should (eql 3 (alist-get 'max_start_failures payload)))
    (should (eq :false (alist-get 'catch_up payload)))))


;;;; Files.

(ert-deftest cmacs-clawtilla-parity-a-file-id-cannot-leave-the-cache ()
  "An attachment id from the daemon names a file inside the cache only."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-files--cache-path)))
  (let* ((process-environment
          (cons (format "XDG_CACHE_HOME=%s"
                        (make-temp-file "clawt-cache" t))
                process-environment))
         (dir (cmacs-clawtilla-files--cache-directory)))
    (unwind-protect
        (progn
          (should (file-in-directory-p
                   (cmacs-clawtilla-files--cache-path "../../etc/passwd") dir))
          (should (equal "passwd"
                         (file-name-nondirectory
                          (cmacs-clawtilla-files--cache-path
                           "../../etc/passwd")))))
      (delete-directory (getenv "XDG_CACHE_HOME") t))))

(ert-deftest cmacs-clawtilla-parity-a-file-says-who-sent-it ()
  "A file's line says \"you\" for the operator and dates what has a date."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-files--meta)))
  (should (equal "you" (cmacs-clawtilla-files--meta '((sender . "user")))))
  (should (string-prefix-p "scout · "
                           (cmacs-clawtilla-files--meta
                            '((sender . "scout") (ts . 1700000000))))))


;;;; Devices.

(ert-deftest cmacs-clawtilla-parity-a-qr-code-is-dark-on-white ()
  "The QR image is black on white with a quiet zone, whatever the theme."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-qr-image)
                    (image-type-available-p 'svg)))
  (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
    (let* ((image (cmacs-clawtilla-qr-image '("101" "010" "111")))
           (svg (plist-get (cdr image) :data)))
      (should (eq 'svg (plist-get (cdr image) :type)))
      ;; Three modules and four of quiet zone on each side.
      (should (string-match-p "viewBox=\"0 0 11 11\"" svg))
      (should (string-match-p "fill=\"white\"" svg))
      (should (string-match-p "fill=\"black\"" svg))
      ;; The first dark module sits past the quiet zone.
      (should (string-match-p "M4 4h1v1h-1z" svg)))))

(ert-deftest cmacs-clawtilla-parity-no-encoder-shows-the-link ()
  "Without a QR encoder the pairing link itself is shown."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-qr-insert)))
  (cmacs-clawtilla-parity-tests--with-asks nil
    (with-temp-buffer
      (should (eq 'text (cmacs-clawtilla-qr-insert "clawtilla://pair?x=1")))
      (should (string-match-p "clawtilla://pair\\?x=1" (buffer-string))))))


;;;; Pushed events.

(defconst cmacs-clawtilla-parity-tests--pushed
  '("agent.changed" "agent.failover" "agent.idle_stopped" "agent.state"
    "broker.changed" "decision.asked" "decision.deleted" "device.paired"
    "image.finished" "image.progress" "memory.changed" "notice.changed"
    "routine.turned_off" "sentinel.finished" "steps.replayed"
    "task.tree_budget" "turn.no_reply" "turn.steered")
  "The pushed events the GTK client handles that this one once never named.")

(ert-deftest cmacs-clawtilla-parity-every-pushed-event-is-heard ()
  "Each pushed event is in the table of what the daemon pushes."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (boundp 'cmacs-clawtilla-events-table)))
  (dolist (kind cmacs-clawtilla-parity-tests--pushed)
    (should (assoc kind cmacs-clawtilla-events-table))))

(ert-deftest cmacs-clawtilla-parity-a-download-says-how-far ()
  "`image.progress' fills the download table and `image.finished' empties it."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-events--on-event)))
  (let ((cmacs-clawtilla-image-progress (make-hash-table :test 'equal))
        (conn (cmacs-clawtilla--connection-create :handle 0 :name "t")))
    (cmacs-clawtilla-events--on-event
     conn "image.progress"
     '((subject . "debian-13") (detail (done . 512) (total . 1024))))
    (should (string-match-p "50%"
                            (cmacs-clawtilla-image-progress-label
                             "debian-13")))
    (cmacs-clawtilla-events--on-event
     conn "image.finished" '((subject . "debian-13")))
    (should (null (cmacs-clawtilla-image-progress-label "debian-13")))))


;;;; The pages.

(ert-deftest cmacs-clawtilla-parity-steps-fit-on-a-line ()
  "Saved steps are summarised as a count and the first four."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-steps--line)))
  (should (equal "0 steps" (cmacs-clawtilla-steps--line nil)))
  (should (equal "1 step: click" (cmacs-clawtilla-steps--line '("click"))))
  (should (equal "5 steps: a · b · c · d …"
                 (cmacs-clawtilla-steps--line '("a" "b" "c" "d" "e")))))

(ert-deftest cmacs-clawtilla-parity-the-ledger-draws-the-librarys-rows ()
  "Spending draws each group with the library's subtitle and cost."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (fboundp 'cmacs-clawtilla-spending--draw)))
  (cmacs-clawtilla-parity-tests--with-asks
      '(("ledger-view" . "{\"groups\":[{\"subtitle\":\"12 turns\",\"cost\":\"$1.50\"}],
                           \"total_cost\":\"$1.50\",\"unpriced\":\"2 turns had no price\",
                           \"csv_name\":\"spending.csv\"}"))
    (cl-letf (((symbol-function 'cmacs-clawtilla-enum)
               (lambda (family)
                 (pcase family
                   ("usage-period" '(((nick . "0") (label . "Today"))))
                   ("usage-group" '(((nick . "agent") (label . "Agent"))))))))
      (with-temp-buffer
        (cmacs-clawtilla-page-mode)
        (setq cmacs-clawtilla-page--name "spending")
        (setq cmacs-clawtilla-page--data
              (list (list 'ledger
                          '((groups ((key . "scout")))
                            (total (turns . 12)))
                          "{\"groups\":[{\"key\":\"scout\"}]}" nil)))
        (let ((inhibit-read-only t))
          (cmacs-clawtilla-spending--draw))
        (let ((drawn (buffer-string)))
          (should (string-match-p "Today, by agent" drawn))
          (should (string-match-p "scout +\\$1\\.50" drawn))
          (should (string-match-p "12 turns" drawn))
          (should (string-match-p "2 turns had no price" drawn)))))))

(ert-deftest cmacs-clawtilla-parity-new-modes-are-evil-ready ()
  "The two new modes own the shared keys and register with Evil."
  (skip-unless (and (cmacs-clawtilla-parity-tests--available-p)
                    (boundp 'cmacs-clawtilla-page-mode-map)))
  (require 'cmacs-clawtilla-devices nil t)
  (dolist (entry '((cmacs-clawtilla-page-mode . "cmacs-clawtilla-page.el")
                   (cmacs-clawtilla-pairing-mode
                    . "cmacs-clawtilla-devices.el")))
    (let ((map (symbol-value (intern (format "%s-map" (car entry)))))
          (source (cmacs-clawtilla-parity-tests--source (cdr entry))))
      (dolist (key '("TAB" "C-j" "C-k" "g j" "g k" "g r" "q"))
        (let ((own (copy-keymap map)))
          (set-keymap-parent own nil)
          (should (lookup-key own (kbd key)))))
      (when source
        (should (string-match-p
                 (regexp-quote (format "(cmacs-clawtilla-setup-evil %s-map"
                                       (car entry)))
                 source))))))

(provide 'cmacs-clawtilla-parity-tests)

;;; cmacs-clawtilla-parity-tests.el ends here
