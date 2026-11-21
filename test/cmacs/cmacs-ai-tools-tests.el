;;; cmacs-ai-tools-tests.el --- The migrated cmacs-ai tool family  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-ai-tools.el replaces the handlers of
;; cmacs/mcp/cmacs-mcp-tools-ai.c while that file stays as the fallback,
;; so the first thing tested is that the two have not drifted: every
;; migrated tool has the C tool's name, its parameters in its order,
;; their types and the same required set.
;;
;; The rest is behaviour, with the model, the embedder and libresearch
;; stubbed: an asynchronous tool answers from the primitive's callback
;; and never before it, a failure arrives as a failure, a provider name
;; that names nothing never reaches a client, and the throwaway client
;; is freed.
;;
;; Everything runs against a private registry with the C mirror stubbed,
;; so nothing registered here reaches the MCP surface of the Emacs
;; running the tests.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cmacs-capability)

(defconst cmacs-ai-tools-tests--migrated
  '("ai_prompt" "ai_call" "generate_image" "ai_list_providers"
    "ai_embed_similarity" "ai_open_chat" "ai_research" "ai_web_fetch"
    "ai_lql")
  "The C tools cmacs-ai-tools.el provides.")

(defconst cmacs-ai-tools-tests--left-in-c
  '("ai_list_models")
  "The C tools deliberately not migrated; see the file's commentary.")

(defun cmacs-ai-tools-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-ai-tools.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun cmacs-ai-tools-tests--c-tools (file)
  "Parse the MCP tool registrations in the C FILE.
Return a list of (NAME PARAMS REQUIRED): PARAMS is a list of
\(PARAM . TYPE) in schema order, REQUIRED the list of required names."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((starts nil) (out nil))
      (while (re-search-forward "mcp_tool_new (\"\\([a-z_]+\\)\"" nil t)
        (push (cons (match-string 1) (match-beginning 0)) starts))
      (setq starts (nreverse starts))
      (while starts
        (let ((name (car (car starts)))
              (beg (cdr (car starts)))
              (end (if (cdr starts) (cdr (cadr starts)) (point-max)))
              (params nil) (required nil))
          (goto-char beg)
          (while (re-search-forward
                  "\\\\\"\\([a-z_]+\\)\\\\\":{\\\\\"type\\\\\":\\\\\"\\([a-z]+\\)\\\\\""
                  end t)
            (push (cons (match-string 1) (match-string 2)) params))
          (goto-char beg)
          (when (re-search-forward "\\\\\"required\\\\\":\\[\\([^]]*\\)\\]" end t)
            (let ((list (match-string 1)) (at 0))
              (while (string-match "\\\\\"\\([a-z_]+\\)\\\\\"" list at)
                (push (match-string 1 list) required)
                (setq at (match-end 0)))))
          (push (list name (nreverse params) (nreverse required)) out))
        (setq starts (cdr starts)))
      (nreverse out))))

(defmacro cmacs-ai-tools-tests--with-family (&rest body)
  "Run BODY with a private registry holding only the cmacs-ai family."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       (let ((load-prefer-newer t))
         (load (expand-file-name "lisp/cmacs/cmacs-ai-tools"
                                 (cmacs-ai-tools-tests--root))
               nil t))
       ,@body)))

(defun cmacs-ai-tools-tests--call (name json)
  "Start the tool NAME with JSON; return a cell that receives the reply.
The cell's car becomes (STATUS TEXT) when the tool settles."
  (let ((cell (list nil)))
    (cmacs-brigade-call-tool-async
     name json (lambda (status text) (setcar cell (list status text))))
    cell))

(defun cmacs-ai-tools-tests--run-timers ()
  "Let zero-delay timers run."
  (accept-process-output nil 0.05))


;;;; The family is the C family

(ert-deftest cmacs-ai-tools-test-family-matches-c ()
  "Every migrated tool has its C twin's name, parameters, types and required set."
  (let* ((root (cmacs-ai-tools-tests--root))
         (file (and root (expand-file-name
                          "cmacs/mcp/cmacs-mcp-tools-ai.c" root))))
    (skip-unless (and file (file-readable-p file)))
    (cmacs-ai-tools-tests--with-family
      (let ((c (cmacs-ai-tools-tests--c-tools file)))
        ;; Every C tool is accounted for: migrated here, or named as
        ;; left behind.  A tool added to the C file fails this until
        ;; someone decides which.
        (should (equal (sort (mapcar #'car c) #'string<)
                       (sort (append cmacs-ai-tools-tests--migrated
                                     cmacs-ai-tools-tests--left-in-c
                                     nil)
                             #'string<)))
        (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                                     (cmacs-capability-describe))
                             #'string<)
                       (sort (copy-sequence cmacs-ai-tools-tests--migrated)
                             #'string<)))
        (dolist (name cmacs-ai-tools-tests--migrated)
          (pcase-let* ((`(,_ ,params ,required) (assoc name c))
                       (entry (cmacs-capability-describe-tool name)))
            (ert-info ((format "tool %s" name))
              (should entry)
              (should (equal (mapcar (lambda (p)
                                       (cons (plist-get p :name)
                                             (plist-get p :type)))
                                     (plist-get entry :params))
                             params))
              (should (equal (cl-loop for p in (plist-get entry :params)
                                      when (plist-get p :required)
                                      collect (plist-get p :name))
                             required)))))))))

(ert-deftest cmacs-ai-tools-test-surfaces ()
  "The `ai_' tools stay off the agents surface; `generate_image' is on it.
A model handed `ai_prompt' can call itself."
  (skip-unless (cmacs-ai-tools-tests--root))
  (cmacs-ai-tools-tests--with-family
    (dolist (name cmacs-ai-tools-tests--migrated)
      (let ((surfaces (plist-get (cmacs-capability-describe-tool name)
                                 :surfaces)))
        (ert-info ((format "tool %s" name))
          (should (memq 'mcp surfaces))
          (should (memq 'dbus surfaces))
          (if (string-prefix-p "ai_" name)
              (should-not (memq 'agents surfaces))
            (should (memq 'agents surfaces))))))
    ;; The model calls and the long requests must not be waited for.
    (dolist (name '("ai_prompt" "ai_call" "generate_image"
                    "ai_embed_similarity" "ai_research" "ai_web_fetch"
                    "ai_lql"))
      (should (plist-get (cmacs-capability-describe-tool name) :async)))))


;;;; Behaviour

(defmacro cmacs-ai-tools-tests--with-model (bindings &rest body)
  "Run BODY with the client, session and stream primitives stubbed.
BINDINGS is a list of (VAR) cells bound for BODY: `stream' receives the
stream callback, `loop' the tool-loop callback, `log' a list of what
was called."
  (declare (indent 1) (debug t))
  (ignore bindings)
  `(let ((stream nil) (loop nil) (log nil)
         (cmacs-ai-default-provider 'claude)
         (cmacs-ai-default-model nil))
     (ignore stream loop log)
     (cl-letf (((symbol-function 'cmacs-ai-providers)
                (lambda (&rest _) '(claude openai ollama)))
               ((symbol-function 'cmacs-ai-client-new)
                (lambda (&rest args) (push (cons 'client-new args) log) 11))
               ((symbol-function 'cmacs-ai-client-free)
                (lambda (&rest args) (push (cons 'client-free args) log) t))
               ((symbol-function 'cmacs-ai-client-set-system-prompt)
                (lambda (&rest args) (push (cons 'system args) log) t))
               ((symbol-function 'cmacs-ai-session-new)
                (lambda (&rest _) 22))
               ((symbol-function 'cmacs-ai-session-free)
                (lambda (&rest args) (push (cons 'session-free args) log) t))
               ((symbol-function 'cmacs-ai-session-append-message)
                (lambda (&rest args) (push (cons 'append args) log) t))
               ((symbol-function 'cmacs-ai-chat-stream)
                (lambda (&rest args)
                  (push (cons 'stream args) log)
                  (setq stream (nth 2 args))
                  t))
               ((symbol-function 'cmacs-ai-tools-new)
                (lambda (&rest _) 33))
               ((symbol-function 'cmacs-ai-tools-free)
                (lambda (&rest args) (push (cons 'tools-free args) log) t))
               ((symbol-function 'cmacs-ai-tools-run-async)
                (lambda (&rest args)
                  (push (cons 'run args) log)
                  (setq loop (nth 2 args))
                  t)))
       ,@body)))

(ert-deftest cmacs-ai-tools-test-prompt-completes ()
  "`ai_prompt' answers from the stream's end, with the streamed text."
  (skip-unless (and (cmacs-ai-tools-tests--root) (require 'cmacs-ai nil t)))
  (cmacs-ai-tools-tests--with-family
    (cmacs-ai-tools-tests--with-model ()
      (let ((reply (cmacs-ai-tools-tests--call
                    "ai_prompt"
                    "{\"prompt\":\"hi\",\"provider\":\"openai\",\"system\":\"be brief\",\"model\":\"m1\"}")))
        ;; Started, not answered: nothing waited for the model.
        (should stream)
        (should-not (car reply))
        (should (equal (assq 'client-new log) '(client-new openai "m1")))
        (should (equal (assq 'system log) '(system 11 "be brief")))
        (should (equal (cdr (assq 'stream log)) (list 22 "hi" stream)))
        (funcall stream '(:start))
        (funcall stream '(:delta "Hel"))
        (funcall stream '(:delta "lo"))
        (should-not (car reply))
        (funcall stream '(:end :text "" :stop end))
        (should (equal (car reply) '(ok "Hello")))
        ;; The throwaway session and client are freed, once.
        (cmacs-ai-tools-tests--run-timers)
        (should (equal (assq 'session-free log) '(session-free 22)))
        (should (equal (assq 'client-free log) '(client-free 11)))))))

(ert-deftest cmacs-ai-tools-test-prompt-fails ()
  "A stream error is a failed call, and still frees the client."
  (skip-unless (and (cmacs-ai-tools-tests--root) (require 'cmacs-ai nil t)))
  (cmacs-ai-tools-tests--with-family
    (cmacs-ai-tools-tests--with-model ()
      (let ((reply (cmacs-ai-tools-tests--call "ai_prompt"
                                               "{\"prompt\":\"hi\"}")))
        ;; No provider named: the configured default.
        (should (equal (assq 'client-new log) '(client-new claude nil)))
        (should-not (assq 'system log))
        (funcall stream '(:error "usage limit reached"))
        (should (equal (car reply) '(error "usage limit reached")))
        ;; A late second payload must not answer twice.
        (funcall stream '(:end :text "late" :stop end))
        (should (equal (car reply) '(error "usage limit reached")))
        (cmacs-ai-tools-tests--run-timers)
        (should (= 1 (cl-count 'client-free log :key #'car)))))))

(ert-deftest cmacs-ai-tools-test-prompt-refuses-bad-arguments ()
  "An unknown provider or an empty prompt never reaches a client."
  (skip-unless (and (cmacs-ai-tools-tests--root) (require 'cmacs-ai nil t)))
  (cmacs-ai-tools-tests--with-family
    (cmacs-ai-tools-tests--with-model ()
      (let ((reply (cmacs-ai-tools-tests--call
                    "ai_prompt"
                    "{\"prompt\":\"hi\",\"provider\":\"no-such-provider-xyzzy\"}")))
        (should (eq (car (car reply)) 'error))
        (should (string-match-p "Unknown provider" (cadr (car reply))))
        ;; Looked up, not interned.
        (should-not (intern-soft "no-such-provider-xyzzy")))
      (let ((reply (cmacs-ai-tools-tests--call "ai_prompt"
                                               "{\"prompt\":\"\"}")))
        (should (eq (car (car reply)) 'error))
        (should (string-match-p "missing .prompt." (cadr (car reply)))))
      (should-not (assq 'client-new log)))))

(ert-deftest cmacs-ai-tools-test-call-runs-tool-loop ()
  "`ai_call' with tools runs the loop on a worker, not a stream."
  (skip-unless (and (cmacs-ai-tools-tests--root) (require 'cmacs-ai nil t)))
  (cmacs-ai-tools-tests--with-family
    (cmacs-ai-tools-tests--with-model ()
      (let ((reply (cmacs-ai-tools-tests--call
                    "ai_call" "{\"prompt\":\"list files\",\"tools\":true}")))
        (should loop)
        (should-not stream)
        (should (equal (assq 'append log) '(append 22 user "list files")))
        (should (equal (cdr (assq 'run log)) (list 22 33 loop)))
        (funcall loop '(:text "three files"))
        (should (equal (car reply) '(ok "three files")))
        (cmacs-ai-tools-tests--run-timers)
        (should (equal (assq 'tools-free log) '(tools-free 33)))))
    ;; Without tools it is the plain streamed prompt.
    (cmacs-ai-tools-tests--with-model ()
      (cmacs-ai-tools-tests--call "ai_call" "{\"prompt\":\"hi\"}")
      (should stream)
      (should-not loop))))

(ert-deftest cmacs-ai-tools-test-embed-similarity ()
  "`ai_embed_similarity' answers with the cosine, to six places."
  (skip-unless (cmacs-ai-tools-tests--root))
  (cmacs-ai-tools-tests--with-family
    (let ((pending nil) (asked nil))
      (cl-letf (((symbol-function 'cmacs-ai-embed-async)
                 (lambda (&rest args)
                   (setq asked args pending (nth 1 args))
                   7))
                ((symbol-function 'cmacs-ai-embed-cosine)
                 (lambda (&rest _) 0.5)))
        (let ((reply (cmacs-ai-tools-tests--call
                      "ai_embed_similarity"
                      "{\"a\":\"a cat\",\"b\":\"a kitten\",\"model\":\"nomic\"}")))
          (should-not (car reply))
          (should (equal (nth 0 asked) '("a cat" "a kitten")))
          (should (equal (nth 3 asked) "nomic"))
          (funcall pending '(:ok ([1.0 0.0] [0.5 0.5])))
          (should (equal (car reply) '(ok "0.500000"))))
        (let ((reply (cmacs-ai-tools-tests--call
                      "ai_embed_similarity" "{\"a\":\"x\",\"b\":\"y\"}")))
          (funcall pending '(:error "ollama is not running"))
          (should (equal (car reply) '(error "ollama is not running"))))))))

(ert-deftest cmacs-ai-tools-test-research ()
  "The libresearch tools hand their options over and answer from the callback."
  (skip-unless (and (cmacs-ai-tools-tests--root)
                    (require 'cmacs-ai-research nil t)))
  (cmacs-ai-tools-tests--with-family
    (let ((pending nil) (asked nil))
      (cl-letf (((symbol-function 'cmacs-ai-research-request)
                 (lambda (kind arg callback &rest options)
                   (setq asked (list kind arg options) pending callback)
                   1)))
        (let ((reply (cmacs-ai-tools-tests--call
                      "ai_research"
                      "{\"question\":\"why?\",\"deep\":true,\"pages\":5}")))
          (should-not (car reply))
          (should (equal asked '(research "why?" (:deep t :pages 5))))
          (funcall pending '(:ok :kind research :text "Because [1]."))
          (should (equal (car reply) '(ok "Because [1]."))))
        (let ((reply (cmacs-ai-tools-tests--call
                      "ai_web_fetch"
                      "{\"url\":\"https://example.org\",\"archive\":\"fallback\",\"max_chars\":500}")))
          (should (equal asked '(fetch "https://example.org"
                                       (:archive "fallback" :max-chars 500))))
          (funcall pending '(:error "connection refused"))
          (should (equal (car reply) '(error "connection refused"))))
        (cmacs-ai-tools-tests--call "ai_lql"
                                    "{\"query\":\"gtk docs\",\"explain\":true}")
        (should (equal asked '(lql "gtk docs" (:max-rows 100 :explain t))))
        ;; The ranges the C handlers checked are still checked, before
        ;; any request is made.
        (setq asked nil)
        (dolist (bad '(("ai_research" . "{\"question\":\"q\",\"pages\":21}")
                       ("ai_web_fetch" . "{\"url\":\"u\",\"archive\":\"sometimes\"}")
                       ("ai_web_fetch" . "{\"url\":\"u\",\"max_chars\":5}")
                       ("ai_lql" . "{\"query\":\"\"}")))
          (let ((reply (cmacs-ai-tools-tests--call (car bad) (cdr bad))))
            (ert-info ((format "%s %s" (car bad) (cdr bad)))
              (should (eq (car (car reply)) 'error)))))
        (should-not asked)))))

(ert-deftest cmacs-ai-tools-test-list-providers ()
  "`ai_list_providers' prints the provider list."
  (skip-unless (cmacs-ai-tools-tests--root))
  (cmacs-ai-tools-tests--with-family
    (cl-letf (((symbol-function 'cmacs-ai-providers)
               (lambda (&rest _) '(claude ollama))))
      (should (equal (car (cmacs-ai-tools-tests--call "ai_list_providers" "{}"))
                     '(ok "(claude ollama)"))))))

(provide 'cmacs-ai-tools-tests)

;;; cmacs-ai-tools-tests.el ends here
