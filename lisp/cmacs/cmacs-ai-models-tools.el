;;; cmacs-ai-models-tools.el --- ai_list_models without blocking  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `ai_list_models' of cmacs/mcp/cmacs-mcp-tools-ai.c, moved onto the
;; capability table (doc_org/cmacs/cmacs-capability.org has the recipe).
;; It is in a file of its own, and was the last `ai_' tool to move,
;; because of how it has to be done.
;;
;; The only primitive is `cmacs-ai-list-models', and it is synchronous:
;; it iterates a private main context until the provider answers, for up
;; to thirty seconds, per provider.  The C handler called it once for
;; every provider in a loop on the dispatch thread.  With a dozen
;; providers and no network that is minutes during which the editor --
;; and under `emacs --gowl' the whole desktop -- does not move.  There is
;; no asynchronous form of it to call instead.
;;
;; So the listing runs in a child: this same binary, `-Q -batch', with a
;; CONSTANT form.  Nothing a caller sent is part of that form.  The
;; provider names (already checked against `cmacs-ai-providers' here)
;; reach it through the environment, and the user's own
;; `cmacs-ai-openai-compatible-endpoints' through a private temporary
;; file, because an endpoint can carry a token and the environment of a
;; process is readable for longer than a 0600 file that is deleted when
;; the child exits.  The tool answers from the process sentinel.
;;
;; What the child sees is what ai-glib reads for itself: its own config
;; file and the provider API-key environment variables, plus the
;; endpoints above.  What it does NOT see is anything set at run time
;; through `cmacs-ai-config-set-api-key' or `cmacs-ai-config-set-base-url'
;; -- there is no reader for those to copy them with.  A provider keyed
;; only that way is reported as unavailable by this tool although a chat
;; with it works.  The fix that removes the child altogether is an
;; asynchronous primitive in cmacs/ai (`ai_provider_list_models_async'
;; is already what the synchronous one wraps).
;;
;; The result is the C's: a JSON object mapping each provider to an
;; array of model names, with a provider that could not be listed
;; mapped to ["(unavailable: REASON)"].

;;; Code:

(require 'cmacs-brigade-registry)

(defvar cmacs-ai-openai-compatible-endpoints)

(declare-function cmacs-ai-providers "cmacs-ai-defuns.c" ())
(declare-function cmacs-ai-list-models "cmacs-ai-stream.c" (&optional provider))

(defconst cmacs-ai-models-tools--timeout 600
  "Seconds `ai_list_models' may take before it is abandoned.
Every provider gets up to thirty seconds of its own inside the child;
this covers twenty of them failing one after another.")

(defconst cmacs-ai-models-tools--providers-env
  "CMACS_AI_MODELS_TOOLS_PROVIDERS"
  "Environment variable naming the providers the child lists.
A comma-separated list of names, each one `cmacs-ai-providers' returned
in the parent.")

(defconst cmacs-ai-models-tools--endpoints-env
  "CMACS_AI_MODELS_TOOLS_ENDPOINTS"
  "Environment variable naming the file holding the parent's endpoints.
The file is the printed value of `cmacs-ai-openai-compatible-endpoints'.")

(defconst cmacs-ai-models-tools--child-form
  (prin1-to-string
   `(let ((names (split-string
                  (or (getenv ,cmacs-ai-models-tools--providers-env) "")
                  "," t))
          (file (getenv ,cmacs-ai-models-tools--endpoints-env))
          (table (make-hash-table :test 'equal)))
      ;; The parent's own variable, printed by the parent: reading it
      ;; back is not reading anything a caller wrote.
      (when (and file (file-readable-p file))
        (setq cmacs-ai-openai-compatible-endpoints
              (with-temp-buffer
                (insert-file-contents file)
                (read (current-buffer)))))
      (dolist (name names)
        (puthash name
                 (condition-case err
                     (apply #'vector (cmacs-ai-list-models (intern name)))
                   (error (vector (format "(unavailable: %s)"
                                          (error-message-string err)))))
                 table))
      (princ (json-serialize table))))
  "The form the child Emacs evaluates, as text.
A constant: the provider names and the endpoints reach it through the
environment, never through this string.")

(defun cmacs-ai-models-tools--providers (provider)
  "Return the provider names to list, as strings.
PROVIDER, when a non-empty string, has to be one `cmacs-ai-providers'
returns -- found with `intern-soft', so an unknown name is reported
rather than interned -- and is then the only one listed."
  (let ((all (mapcar #'symbol-name (cmacs-ai-providers))))
    (if (and (stringp provider) (not (string-empty-p provider)))
        (if (member provider all)
            (list provider)
          (error "Unknown provider `%s' (ai_list_providers lists them)"
                 provider))
      all)))

(defun cmacs-ai-models-tools--list (done provider)
  "List the models of PROVIDER (nil: every provider); answer through DONE.
Returns at once.  DONE is called exactly once, from the child's sentinel
or from the timeout, with the JSON object or an \"Error: ...\" string."
  (let* ((names (cmacs-ai-models-tools--providers provider))
         (bin (expand-file-name invocation-name invocation-directory))
         (lispdir (file-name-directory (locate-library "cmacs-ai")))
         (endpoints (make-temp-file "cmacs-ai-models" nil ".el"))
         (out (generate-new-buffer " *ai-list-models*"))
         (err (generate-new-buffer " *ai-list-models-stderr*"))
         (timer nil)
         (finished nil)
         (proc nil)
         (finish
          (lambda (text)
            ;; The sentinel and the timeout can both get here; the
            ;; caller is answered by whichever is first.
            (unless finished
              (setq finished t)
              (when (timerp timer) (cancel-timer timer))
              (ignore-errors (delete-file endpoints))
              (when (buffer-live-p out) (kill-buffer out))
              (when (buffer-live-p err) (kill-buffer err))
              (funcall done text)))))
    (condition-case failure
        (progn
          ;; `make-temp-file' creates it 0600.
          (with-temp-file endpoints
            (let ((print-length nil) (print-level nil))
              (prin1 (bound-and-true-p cmacs-ai-openai-compatible-endpoints)
                     (current-buffer))))
          (let ((process-environment
                 (append
                  (list (concat cmacs-ai-models-tools--providers-env "="
                                (mapconcat #'identity names ","))
                        (concat cmacs-ai-models-tools--endpoints-env "="
                                endpoints))
                  process-environment)))
            (setq proc
                  (make-process
                   :name "ai-list-models" :buffer out :stderr err
                   :noquery t :connection-type 'pipe
                   :command (list bin "-Q" "-batch" "-L" lispdir
                                  "-l" "cmacs-ai"
                                  "--eval" cmacs-ai-models-tools--child-form)
                   :sentinel
                   (lambda (p _event)
                     (when (memq (process-status p) '(exit signal))
                       (let ((text (and (buffer-live-p out)
                                        (with-current-buffer out
                                          (string-trim (buffer-string))))))
                         (if (and (eq (process-status p) 'exit)
                                  (zerop (process-exit-status p))
                                  text
                                  (string-prefix-p "{" text))
                             (funcall finish text)
                           (funcall
                            finish
                            (format "Error: could not list models: %s"
                                    (if (and (buffer-live-p err)
                                             (> (buffer-size err) 0))
                                        (with-current-buffer err
                                          (string-trim
                                           (buffer-substring-no-properties
                                            (max (point-min)
                                                 (- (point-max) 400))
                                            (point-max))))
                                      (format "the child exited with %s"
                                              (process-exit-status
                                               p)))))))))))))
      (error
       (funcall finish (format "Error: could not start the model listing: %s"
                               (error-message-string failure)))))
    (when (process-live-p proc)
      ;; Slightly inside the registry's own timeout, so the child is
      ;; killed by the answer that reports it rather than left running
      ;; for a caller that has already been told it timed out.
      (setq timer
            (run-at-time
             (- cmacs-ai-models-tools--timeout 10) nil
             (lambda ()
               (when (process-live-p proc) (delete-process proc))
               (funcall finish "Error: listing models timed out")))))))

;; Published like the other `ai_' tools (cmacs-ai-tools.el): to MCP,
;; D-Bus and the CLI, not to in-process agents.
(cmacs-brigade-deftool ai-list-models
  "List the model names each cmacs-ai provider offers, as a JSON \
object mapping provider to an array of models.  Optional \
'provider' restricts the query to one provider; otherwise all \
providers are queried (unavailable ones report inline)."
    ((provider string "Provider name" :optional t))
  :group 'ai :surfaces '(mcp dbus cli) :returns 'json
  :async t :timeout cmacs-ai-models-tools--timeout
  :example "emacsctl tool ai list-models --provider ollama"
  (cmacs-ai-models-tools--list done provider))

(provide 'cmacs-ai-models-tools)

;;; cmacs-ai-models-tools.el ends here
