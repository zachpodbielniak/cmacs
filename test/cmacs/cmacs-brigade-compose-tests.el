;;; cmacs-brigade-compose-tests.el --- Composing tasks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three things are worth testing here and they are not the transient.
;;
;; First, the writer: `cmacs-brigade-plan-append-task' composes org
;; structure out of text a human typed, and text a human typed contains
;; asterisks and newlines.  A prompt line starting with `*' at column
;; zero silently becomes a second headline and takes the rest of the
;; prompt with it, which produces a task that runs half its instruction.
;;
;; Second, the draft: what a model proposes is checked against what
;; actually exists before it is written into a plan.  An invented agent
;; name is a task that fails at start with a puzzling error, and an
;; invented tool is worse -- it looks like it worked.
;;
;; Third, the keys: every command the dashboard binds must exist.  That
;; is the failure mode this subsystem has actually shipped, repeatedly --
;; a capability registered and nothing invoking it, or a key bound to a
;; function that was never loaded.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-plan nil 'noerror)
(require 'cmacs-brigade-compose nil 'noerror)
(require 'cmacs-brigade-dashboard nil 'noerror)

(defun cmacs-brigade-compose-tests--available-p ()
  (and (featurep 'cmacs-brigade-compose)
       (fboundp 'cmacs-brigade-task-adopt)))

(defmacro cmacs-brigade-compose-tests--in-dir (&rest body)
  "Run BODY with FILE bound to a fresh plan path in a temporary directory."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "cmacs-brigade-compose" t))
          (file (expand-file-name "compose.org" dir))
          (cmacs-brigade-compose-plan-file file))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory dir t))))


;;;; Writing a task into a plan

(ert-deftest cmacs-brigade-compose-append-writes-a-task ()
  "Appending a task creates the file, the headline and the properties."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-compose-tests--in-dir
    (let ((id (cmacs-brigade-plan-append-task
               file (list :title "Do the thing"
                          :prompt "Find out what changed."
                          :agent "researcher"
                          :model "claude-code/sonnet"
                          :budget "0.50"
                          :tools '(memory_search web_search)))))
      (should (stringp id))
      (with-current-buffer (find-file-noselect file)
        (let ((text (buffer-string)))
          (should (string-match-p "^\\* TODO Do the thing" text))
          (should (string-match-p ":brigade:" text))
          (should (string-match-p ":AGENT:  researcher" text))
          (should (string-match-p ":MODEL:  claude-code/sonnet" text))
          (should (string-match-p ":BUDGET:  0\\.50" text))
          (should (string-match-p ":TOOLS:  memory_search, web_search" text))
          (should (string-match-p "Find out what changed\\." text)))))))

(ert-deftest cmacs-brigade-compose-append-omits-empty-properties ()
  "An unset field is absent, not written blank.

An empty :MODEL: is a different request from no :MODEL: -- the runner
reads the absent one as \"whatever the agent says\" and the empty one as
a model named nothing."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-compose-tests--in-dir
    (cmacs-brigade-plan-append-task
     file (list :title "Bare" :prompt "Do it." :agent "researcher"
                :model nil :budget "" :tools nil))
    (with-current-buffer (find-file-noselect file)
      (let ((text (buffer-string)))
        (should (string-match-p ":AGENT:" text))
        (should-not (string-match-p ":MODEL:" text))
        (should-not (string-match-p ":BUDGET:" text))
        (should-not (string-match-p ":TOOLS:" text))))))

(ert-deftest cmacs-brigade-compose-prompt-stars-are-not-headlines ()
  "A prompt containing `*' at column zero stays inside its own task.

The bug this guards is silent: org reads the bullet as a headline, the
rest of the prompt becomes a separate entry, and the agent runs the
first sentence of its instruction."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-compose-tests--in-dir
    (cmacs-brigade-plan-append-task
     file (list :title "Bulleted"
                :prompt "Check these:\n* the parser\n* the writer\nThen report."
                :agent "researcher"))
    (with-current-buffer (find-file-noselect file)
      ;; Exactly one headline in the file.
      (should (= 1 (length (org-map-entries #'point-marker nil 'file))))
      (goto-char (point-min))
      (should (re-search-forward "^  \\* the parser$" nil t))
      (should (re-search-forward "^  Then report\\.$" nil t)))))

(ert-deftest cmacs-brigade-compose-title-is-reduced-to-one-line ()
  "A multi-line or star-prefixed title cannot break the headline."
  (skip-unless (featurep 'cmacs-brigade-plan))
  (should (equal (cmacs-brigade-plan--headline-text "** hi\nthere")
                 "hi there"))
  (should (equal (cmacs-brigade-plan--headline-text "   ") "Untitled task"))
  (should (= 70 (length (cmacs-brigade-plan--headline-text
                         (make-string 200 ?x))))))

(ert-deftest cmacs-brigade-compose-read-task-round-trips ()
  "What was written as intent reads back as intent."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-compose-tests--in-dir
    (let* ((id (cmacs-brigade-plan-append-task
                file (list :title "Round trip" :prompt "The body."
                           :agent "researcher" :model "claude/x"
                           :budget "1.00" :tools "a, b"
                           :cwd temporary-file-directory)))
           (entry (cmacs-brigade-plan-read-task file id)))
      (should (equal (plist-get entry :title) "Round trip"))
      (should (equal (plist-get entry :prompt) "The body."))
      (should (equal (plist-get entry :agent) "researcher"))
      (should (equal (plist-get entry :model) "claude/x"))
      (should (equal (plist-get entry :tools) "a, b"))
      (should (plist-get entry :cwd)))))


;;;; Cloning

(ert-deftest cmacs-brigade-compose-clone-carries-intent-not-runtime ()
  "A clone copies what the task said and none of what it did."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-compose-tests--in-dir
    (let* ((id (cmacs-brigade-plan-append-task
                file (list :title "Original" :prompt "The work."
                           :agent "researcher" :model "claude-code/sonnet"
                           :budget "0.25" :tools "memory_search")))
           (state (cmacs-brigade-compose--from-record
                   (list :id id :plan file :title "Original"
                         :agent "researcher"
                         ;; runtime fields, none of which may survive
                         :state 'done :turns 12 :cost-micros 310000))))
      (should (equal (plist-get state :prompt) "The work."))
      (should (equal (plist-get state :agent) "researcher"))
      (should (equal (plist-get state :provider) "claude-code"))
      (should (equal (plist-get state :model) "sonnet"))
      (should (equal (plist-get state :tools) "memory_search"))
      (should (string-match-p "\\`Copy of " (plist-get state :title)))
      (should-not (plist-get state :state))
      (should-not (plist-get state :turns))
      (should-not (plist-get state :cost-micros)))))

(ert-deftest cmacs-brigade-compose-clone-gets-a-new-id ()
  "Creating from a clone produces a second task, not a second view of one."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-compose-tests--in-dir
    (let* ((first (cmacs-brigade-plan-append-task
                   file (list :title "Original" :prompt "The work."
                              :agent "researcher")))
           (cmacs-brigade-compose--state
            (cmacs-brigade-compose--from-record
             (list :id first :plan file :agent "researcher")))
           (second (cmacs-brigade-compose-create nil)))
      (should (stringp second))
      (should-not (equal first second))
      (with-current-buffer (find-file-noselect file)
        (should (= 2 (length (org-map-entries #'point-marker nil 'file))))))))

(ert-deftest cmacs-brigade-compose-clone-uses-the-base-agent ()
  "A per-task override derived `r@abcd1234'; the clone says `r'.

Cloning the derived name would point the copy at a definition belonging
to the original, freezing every override where the transient cannot
reach it."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-register-agent :name 'compose-base :prompt "p")
  (let ((derived (cmacs-brigade-agent-derive
                  'compose-base "abcd1234" (list :model "claude/other"))))
    (should (equal (cmacs-brigade-compose--base-agent (list :agent derived))
                   "compose-base"))))


;;;; Reading a draft back

(ert-deftest cmacs-brigade-compose-json-is-found-in-prose ()
  "The object is located, not assumed to be the whole reply."
  (skip-unless (fboundp 'cmacs-brigade-parse-json-object))
  (let ((spec (cmacs-brigade-parse-json-object
               "Sure!  Here you go:\n```json\n{\"title\": \"T\"}\n```\nEnjoy.")))
    (should (equal (alist-get 'title spec) "T")))
  (should-not (cmacs-brigade-parse-json-object "no json here"))
  (should-not (cmacs-brigade-parse-json-object nil)))

(ert-deftest cmacs-brigade-compose-draft-drops-invented-names ()
  "An agent, tool or provider the model made up does not reach the plan."
  (skip-unless (featurep 'cmacs-brigade-compose))
  (let ((state (cmacs-brigade-compose--state-from-json
                "{\"title\":\"T\",\"prompt\":\"P\",\"agent\":\"no-such-agent\",\
\"tools\":[\"no_such_tool\"],\"provider\":\"no-such-provider\",\
\"model\":\"m\",\"budget\":0}"
                "the request")))
    (should (equal (plist-get state :title) "T"))
    (should (equal (plist-get state :prompt) "P"))
    (should-not (plist-get state :agent))
    (should-not (plist-get state :tools))
    (should-not (plist-get state :provider))
    ;; A model name without a provider to read it against is meaningless.
    (should-not (plist-get state :model))
    ;; Zero is no ceiling, which is the same request as not setting one.
    (should-not (plist-get state :budget))))

(ert-deftest cmacs-brigade-compose-draft-failure-still-delivers-once ()
  "A provider that cannot even be reached still fills the menu in, once.

The callback is what opens the transient, so a path that drops it
leaves the request in limbo with nothing on screen -- and a double call
would open two menus over one request."
  (skip-unless (featurep 'cmacs-brigade-compose))
  (let ((cmacs-brigade-compose-author-provider 'no-such-provider)
        (calls 0) (got nil))
    (cmacs-brigade-compose--author
     "do the thing" (lambda (s) (setq calls (1+ calls) got s)))
    (should (= calls 1))
    (should (equal (plist-get got :prompt) "do the thing"))))

(ert-deftest cmacs-brigade-compose-draft-falls-back-to-your-words ()
  "With nothing to draft with, the request itself becomes the prompt."
  (skip-unless (featurep 'cmacs-brigade-compose))
  (let ((state (cmacs-brigade-compose--fallback-state "do the thing")))
    (should (equal (plist-get state :prompt) "do the thing"))
    (should (equal (plist-get state :title) "do the thing"))))


;;;; The model string

(ert-deftest cmacs-brigade-compose-never-emits-a-half-model ()
  "A provider with no model is completed or dropped, never written bare.

`claude-code/' parses as a model *name* on the default provider, so the
half-answer runs something other than what was asked for."
  (skip-unless (featurep 'cmacs-brigade-compose))
  (let ((cmacs-brigade-compose--state nil))
    (should-not (cmacs-brigade-compose--model-string)))
  (let ((cmacs-brigade-compose--state '(:provider "claude-code" :model "sonnet")))
    (should (equal (cmacs-brigade-compose--model-string) "claude-code/sonnet")))
  ;; A model with no provider is meaningful: it pins the model on the
  ;; default provider, which is what a bare "gpt-oss:20b" has meant.
  (let ((cmacs-brigade-compose--state '(:model "gpt-oss:20b")))
    (should (equal (cmacs-brigade-compose--model-string) "gpt-oss:20b")))
  ;; Provider alone, with no model list to complete from, must not
  ;; produce a trailing slash.
  (let ((cmacs-brigade-compose--state '(:provider "no-such-provider"))
        (cmacs-brigade-compose--model-cache nil))
    (let ((s (cmacs-brigade-compose--model-string)))
      (should (or (null s) (not (string-suffix-p "/" s)))))))


;;;; Keys

(ert-deftest cmacs-brigade-compose-dashboard-keys-are-bound ()
  "Every dashboard key resolves to a command that exists.

The recurring failure in this subsystem is a key wired to a function
nothing ever loaded; the halves each work and the whole is void."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (dolist (key '("n" "V" "C" "x" "s" "K" "d" "o" "g" "c" "p" "a" "m" "b"
                 "t" "A" "N" "T" "?" "q"))
    (let ((cmd (lookup-key cmacs-brigade-dashboard-mode-map (kbd key))))
      (should cmd)
      (should (commandp cmd)))))

(ert-deftest cmacs-brigade-compose-entry-keys-are-bound ()
  "The entry buffer can be submitted and abandoned."
  (skip-unless (featurep 'cmacs-brigade-compose))
  (should (commandp (lookup-key cmacs-brigade-compose-entry-mode-map
                                (kbd "C-c C-c"))))
  (should (commandp (lookup-key cmacs-brigade-compose-entry-mode-map
                                (kbd "C-c C-k")))))

(ert-deftest cmacs-brigade-compose-entry-submits-its-text ()
  "Submitting hands the buffer's text to the callback and closes up."
  (skip-unless (featurep 'cmacs-brigade-compose))
  (let ((got nil))
    (with-current-buffer (get-buffer-create "*brigade ask*")
      (erase-buffer)
      (cmacs-brigade-compose-entry-mode)
      (setq cmacs-brigade-compose--entry-callback (lambda (s) (setq got s)))
      (insert "  survey the notes\n")
      (cmacs-brigade-compose-entry-submit))
    (should (equal got "survey the notes"))
    (should-not (get-buffer "*brigade ask*"))))

(ert-deftest cmacs-brigade-compose-refuses-an-empty-prompt ()
  "Creating with nothing to do says so rather than filing an empty task."
  (skip-unless (cmacs-brigade-compose-tests--available-p))
  (cmacs-brigade-compose-tests--in-dir
    (let ((cmacs-brigade-compose--state '(:title "Nothing")))
      (should-error (cmacs-brigade-compose-create nil) :type 'user-error))))

;;;; Declared but never required
;;
;; The single most repeated defect in this subsystem: a file names an
;; Elisp function with `declare-function' -- which silences the byte
;; compiler and loads nothing -- and the call dies with "Symbol's
;; function definition is void" the first time anyone reaches that code
;; path.  It has now happened to `cmacs-brigade-start-task',
;; `cmacs-ai-make-session' and `cmacs-whisper-model-path'.
;;
;; A `declare-function' pointing at a .c file is fine: those are DEFUNs,
;; present or absent at build time and correctly guarded with `fboundp'.
;; One pointing at an Elisp library is a promise that the library is
;; loaded, and only `require' keeps it.

(defun cmacs-brigade-compose-tests--declared-elisp (file)
  "Return the Elisp libraries FILE declares functions from but never requires."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((declared nil) (required nil) (missing nil))
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*(declare-function[ \t\n]+[^ \t\n]+[ \t\n]+\"\\([^\"]+\\)\""
              nil t)
        (let ((lib (match-string 1)))
          ;; .c means a DEFUN: compiled in or not, and guarded already.
          (unless (string-suffix-p ".c" lib)
            (cl-pushnew (file-name-sans-extension lib) declared :test #'equal))))
      (goto-char (point-min))
      (while (re-search-forward "(require '\\([^ \t\n)]+\\)" nil t)
        (push (match-string 1) required))
      (dolist (lib declared)
        (unless (member lib required)
          (push lib missing)))
      (nreverse missing))))

(defconst cmacs-brigade-compose-tests--cycle-breaks
  '(("cmacs-brigade-compose.el" . "cmacs-brigade-dashboard"))
  "Declarations that must stay declarations, with the reason.

The dashboard requires compose -- for its `n', `V', `C' and `x' keys and
for the provider/model reader -- so compose requiring the dashboard back
would be a load cycle.  Both call sites in compose are `fboundp'-guarded
and do nothing useful when the dashboard is absent, which is the correct
shape for a back-reference.  Anything else on this list needs the same
argument made for it in writing.")

(ert-deftest cmacs-brigade-compose-no-declared-but-unrequired-libraries ()
  "Every brigade file requires the Elisp libraries it declares functions from.

The exceptions are load cycles, listed and argued for above.  Everything
else is a void-function waiting for the first person to reach that code
path -- which is how `cmacs-brigade-start-task', `cmacs-ai-make-session'
and `cmacs-whisper-model-path' each shipped."
  (let ((dir (file-name-directory (locate-library "cmacs-brigade")))
        (bad nil))
    (skip-unless dir)
    (dolist (file (directory-files dir t "\\`cmacs-brigade.*\\.el\\'"))
      (let ((base (file-name-nondirectory file)))
        (dolist (lib (cmacs-brigade-compose-tests--declared-elisp file))
          (unless (member (cons base lib)
                          cmacs-brigade-compose-tests--cycle-breaks)
            (push (format "%s declares from %s but never requires it" base lib)
                  bad)))))
    (should (equal nil (nreverse bad)))))

(provide 'cmacs-brigade-compose-tests)

;;; cmacs-brigade-compose-tests.el ends here
