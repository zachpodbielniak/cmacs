;;; cmacs-ai-embed-tests.el --- ERT tests for cmacs-ai-embed  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the AiEmbedder surface (`cmacs-ai-embed' and friends) and
;; for the brigade memory layer's choice between it and curl.
;;
;; Split in two.  Most of these need no server: the model table and the
;; default model come from a static table compiled into ai-glib, the
;; cosine is arithmetic, and the argument checks reject before any
;; request is made.  Only the handful marked with
;; `cmacs-ai-embed-tests--server-p' actually talk to ollama, and they
;; skip when nothing answers -- so the file is meaningful on a headless
;; machine and still covers the real round trip on a workstation.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)

(require 'cmacs-brigade-memory nil 'noerror)

(defvar cmacs-ai-embed-tests--server 'unknown
  "Cached liveness of the embedding server, so each test does not probe.")

(defun cmacs-ai-embed-tests--server-p ()
  "Return non-nil when a local embedding server answers."
  (when (eq cmacs-ai-embed-tests--server 'unknown)
    (setq cmacs-ai-embed-tests--server
          (and (fboundp 'cmacs-ai-embed)
               (condition-case nil
                   (and (cmacs-ai-embed "ping" 'ollama) t)
                 (error nil)))))
  cmacs-ai-embed-tests--server)


;;;; Model discovery (static tables -- no server)

(ert-deftest cmacs-ai-embed-test-default-model ()
  "`cmacs-ai-embed-default-model' names a model without asking a server."
  (skip-unless (fboundp 'cmacs-ai-embed-default-model))
  (let ((m (cmacs-ai-embed-default-model 'ollama)))
    (should (stringp m))
    (should (> (length m) 0))))

(ert-deftest cmacs-ai-embed-test-models-table ()
  "`cmacs-ai-embed-models' returns plists carrying a usable dimension."
  (skip-unless (fboundp 'cmacs-ai-embed-models))
  (let ((models (cmacs-ai-embed-models 'ollama)))
    (should models)
    (dolist (m models)
      (should (stringp (plist-get m :id)))
      ;; :dimensions is what an index is built for; a model that does
      ;; not report one would silently produce an unusable index.
      (should (integerp (plist-get m :dimensions)))
      (should (> (plist-get m :dimensions) 0)))))

(ert-deftest cmacs-ai-embed-test-default-model-is-listed ()
  "The default model appears in the published table."
  (skip-unless (fboundp 'cmacs-ai-embed-models))
  (let ((default (cmacs-ai-embed-default-model 'ollama))
        (ids (mapcar (lambda (m) (plist-get m :id))
                     (cmacs-ai-embed-models 'ollama))))
    (should (member default ids))))


;;;; Provider selection

(ert-deftest cmacs-ai-embed-test-rejects-non-embedding-provider ()
  "A provider that serves no embeddings is refused, not attempted.

claude-code is a CLI agent; asking it for a vector is a category error
and should say so rather than fail somewhere inside a request."
  (skip-unless (fboundp 'cmacs-ai-embed))
  (should-error (cmacs-ai-embed "hello" 'claude-code)))


;;;; Cosine

(ert-deftest cmacs-ai-embed-test-cosine-known-values ()
  "Cosine is 1, 0 and -1 for identical, orthogonal and opposite vectors."
  (skip-unless (fboundp 'cmacs-ai-embed-cosine))
  (let ((a [1.0 0.0 0.0]))
    (should (< (abs (- (cmacs-ai-embed-cosine a [1.0 0.0 0.0]) 1.0)) 1e-6))
    (should (< (abs (cmacs-ai-embed-cosine a [0.0 1.0 0.0])) 1e-6))
    (should (< (abs (+ (cmacs-ai-embed-cosine a [-1.0 0.0 0.0]) 1.0)) 1e-6))))

(ert-deftest cmacs-ai-embed-test-cosine-ignores-magnitude ()
  "Cosine compares direction, so scaling a vector does not change it."
  (skip-unless (fboundp 'cmacs-ai-embed-cosine))
  (should (< (abs (- (cmacs-ai-embed-cosine [1.0 2.0 3.0] [10.0 20.0 30.0])
                     1.0))
             1e-6)))

(ert-deftest cmacs-ai-embed-test-cosine-accepts-lists ()
  "A list of numbers works wherever a vector does."
  (skip-unless (fboundp 'cmacs-ai-embed-cosine))
  (should (< (abs (- (cmacs-ai-embed-cosine '(1.0 0.0) [1.0 0.0]) 1.0)) 1e-6)))

(ert-deftest cmacs-ai-embed-test-cosine-length-mismatch ()
  "Comparing different lengths signals instead of reading past the end."
  (skip-unless (fboundp 'cmacs-ai-embed-cosine))
  (should-error (cmacs-ai-embed-cosine [1.0 0.0] [1.0 0.0 0.0]))
  (should-error (cmacs-ai-embed-cosine [] [])))


;;;; Live round trip

(ert-deftest cmacs-ai-embed-test-single-returns-one-vector ()
  "A string argument yields one vector, not a one-element list."
  (skip-unless (cmacs-ai-embed-tests--server-p))
  (let ((v (cmacs-ai-embed "hello world" 'ollama)))
    (should (vectorp v))
    (should (> (length v) 0))
    (should (cl-every #'numberp v))))

(ert-deftest cmacs-ai-embed-test-batch-returns-list ()
  "A list argument yields a list of vectors, in request order."
  (skip-unless (cmacs-ai-embed-tests--server-p))
  (let ((vs (cmacs-ai-embed '("alpha" "beta" "gamma") 'ollama)))
    (should (listp vs))
    (should (= (length vs) 3))
    (should (cl-every #'vectorp vs))
    ;; One model produces one width; a ragged batch would corrupt an index.
    (should (= 1 (length (seq-uniq (mapcar #'length vs)))))))

(ert-deftest cmacs-ai-embed-test-empty-input ()
  "Embedding nothing is nil, not an error and not a request."
  (skip-unless (fboundp 'cmacs-ai-embed))
  (should (null (cmacs-ai-embed nil))))

(ert-deftest cmacs-ai-embed-test-semantic-ordering ()
  "Related text scores above unrelated text.

The real assertion of the whole feature: a vector nobody can rank with
is worthless, however well-formed."
  (skip-unless (cmacs-ai-embed-tests--server-p))
  (let* ((q  (cmacs-ai-embed "the cat sat on the mat" 'ollama))
         (near (cmacs-ai-embed "a feline rested on the rug" 'ollama))
         (far  (cmacs-ai-embed "quarterly financial report" 'ollama)))
    (should (> (cmacs-ai-embed-cosine q near)
               (cmacs-ai-embed-cosine q far)))))

(ert-deftest cmacs-ai-embed-test-async-delivers ()
  "`cmacs-ai-embed-async' calls back with (:ok VECTORS)."
  (skip-unless (cmacs-ai-embed-tests--server-p))
  (let ((reply nil))
    (cmacs-ai-embed-async '("one" "two") (lambda (r) (setq reply r)) 'ollama)
    (with-timeout (60 (ert-fail "async embed never called back"))
      (while (null reply) (sit-for 0.05)))
    (should (eq (car reply) :ok))
    (should (= (length (cadr reply)) 2))
    (should (cl-every #'vectorp (cadr reply)))))

(ert-deftest cmacs-ai-embed-test-async-cancel ()
  "A cancelled request reports :cancelled, and its id stops being live.

Cancellation is what lets a corpus build be abandoned; without it the
only way out would be to let every queued batch finish."
  (skip-unless (cmacs-ai-embed-tests--server-p))
  (let* ((reply nil)
         (id (cmacs-ai-embed-async "cancel me" (lambda (r) (setq reply r))
                                   'ollama)))
    (should (integerp id))
    (should (eq t (cmacs-ai-embed-cancel id)))
    (with-timeout (30 (ert-fail "cancelled embed never called back"))
      (while (null reply) (sit-for 0.05)))
    (should (equal reply '(:cancelled)))
    ;; The id is retired once the request settles, so a second cancel
    ;; is a no-op rather than a double free.
    (should (null (cmacs-ai-embed-cancel id)))))

(ert-deftest cmacs-ai-embed-test-cancel-unknown-id ()
  "Cancelling an id that was never issued is nil, not an error."
  (skip-unless (fboundp 'cmacs-ai-embed-cancel))
  (should (null (cmacs-ai-embed-cancel 987654))))


(ert-deftest cmacs-ai-embed-test-honours-configured-endpoint ()
  "The embedder talks to the configured base URL, not a built-in default.

Regression: the embedder used to be built with a bare constructor,
which gives the client its own private AiConfig.  The base URL was then
read from that private copy, so `cmacs-ai-config-set-base-url' -- and
`cmacs-brigade-embed-endpoint' layered on it -- did nothing at all.
The symptom was not an error but a silent success: requests kept going
to the default host, and a build pointed at a dead endpoint completed
and wrote a manifest."
  (skip-unless (cmacs-ai-embed-tests--server-p))
  (skip-unless (fboundp 'cmacs-ai-config-set-base-url))
  (let ((live "http://localhost:11434"))
    (unwind-protect
        (progn
          ;; Port 9 (discard) refuses; reaching it must fail.
          (cmacs-ai-config-set-base-url 'ollama "http://127.0.0.1:9")
          (should-error (cmacs-ai-embed "hello" 'ollama))
          ;; And the setting is not one-way: restoring it works again.
          (cmacs-ai-config-set-base-url 'ollama live)
          (should (vectorp (cmacs-ai-embed "hello" 'ollama))))
      (cmacs-ai-config-set-base-url 'ollama live))))


;;;; Brigade backend selection

(ert-deftest cmacs-ai-embed-test-brigade-backend-selection ()
  "The brigade memory layer honours `cmacs-brigade-embed-backend'."
  (skip-unless (fboundp 'cmacs-brigade-memory--embed-backend))
  (let ((cmacs-brigade-embed-backend 'curl))
    (should (eq (cmacs-brigade-memory--embed-backend) 'curl)))
  (let ((cmacs-brigade-embed-backend 'ai-glib))
    ;; ai-glib only when the C surface is actually in this build.
    (should (eq (cmacs-brigade-memory--embed-backend)
                (if (fboundp 'cmacs-ai-embed-async) 'ai-glib 'curl)))))

(ert-deftest cmacs-ai-embed-test-brigade-abort-accepts-both-handles ()
  "`cmacs-brigade-memory--embed-abort' handles either backend's handle.

The two backends return different things -- a process from curl, an
integer id from ai-glib -- and the cancel path sees both."
  (skip-unless (fboundp 'cmacs-brigade-memory--embed-abort))
  ;; nil and an already-finished id are both no-ops, not errors.
  (should-not (cmacs-brigade-memory--embed-abort nil))
  (cmacs-brigade-memory--embed-abort 987654)
  ;; A dead process is left alone rather than deleted twice.
  (let ((proc (start-process "cmacs-embed-test" nil "true")))
    (while (process-live-p proc) (sit-for 0.01))
    (cmacs-brigade-memory--embed-abort proc)
    (should-not (process-live-p proc))))

(ert-deftest cmacs-ai-embed-test-brigade-backends-agree ()
  "curl and ai-glib produce the same vector for the same text.

This is what makes `cmacs-brigade-embed-backend' safe to change: they
speak the same endpoint to the same model, so an index built by one
stays valid under the other and no rebuild is required."
  (skip-unless (cmacs-ai-embed-tests--server-p))
  (skip-unless (fboundp 'cmacs-brigade-memory--embed))
  (skip-unless (executable-find "curl"))
  (let* ((texts '("the compositor shares the editor main loop"))
         (a (let ((cmacs-brigade-embed-backend 'curl))
              (car (cmacs-brigade-memory--embed texts))))
         (b (let ((cmacs-brigade-embed-backend 'ai-glib))
              (car (cmacs-brigade-memory--embed texts)))))
    (should (= (length a) (length b)))
    ;; fp32 round-tripping through JSON moves the last bit or two, so
    ;; compare direction rather than demanding equal floats.
    (should (> (cmacs-ai-embed-cosine a b) 0.9999))))

(provide 'cmacs-ai-embed-tests)

;;; cmacs-ai-embed-tests.el ends here
