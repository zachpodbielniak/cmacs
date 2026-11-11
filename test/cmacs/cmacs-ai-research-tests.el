;;; cmacs-ai-research-tests.el --- ERT tests for libresearch in cmacs-ai  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Covers the libresearch surface: the `libresearch' web_search backend,
;; the `cmacs-ai--libresearch-*' primitives' argument checking, ai-glib's
;; text rendering of canned documents, the Org rendering in
;; cmacs-ai-research.el, the chat slash-command parser, CLI account
;; directories, and one end-to-end request against a stub libresearchd
;; served by this Emacs on a loopback port.
;;
;; The Org renderers and the parser are pure Elisp and run on any build;
;; everything else skips without the C primitives.
;;
;; Run with: make -C test check-cmacs TESTS=cmacs-ai-research-tests

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'cmacs-ai nil 'noerror)
(require 'cmacs-ai-research nil 'noerror)

(declare-function cmacs-ai--libresearch-search "cmacs-ai-libresearch.c" (query callback &optional options))
(declare-function cmacs-ai--libresearch-fetch "cmacs-ai-libresearch.c" (url callback &optional options))
(declare-function cmacs-ai--libresearch-lql "cmacs-ai-libresearch.c" (lql callback &optional options))
(declare-function cmacs-ai--libresearch-research "cmacs-ai-libresearch.c" (question callback &optional options))
(declare-function cmacs-ai--libresearch-poll "cmacs-ai-libresearch.c" (id))
(declare-function cmacs-ai--libresearch-cancel "cmacs-ai-libresearch.c" (id))
(declare-function cmacs-ai--libresearch-format "cmacs-ai-libresearch.c" (kind json &optional max-rows))
(declare-function cmacs-ai--libresearch-default-endpoint "cmacs-ai-libresearch.c" ())

(defvar cmacs-ai-libresearch-url)
(defvar cmacs-ai-libresearch-token-function)
(defvar cmacs-ai-cli-config-dirs)

(defconst cmacs-ai-research-tests--research-doc
  "{\"schema\":\"libresearch.research/1\",
    \"answer\":\"GLib is a utility library [1].\\n* looks like a headline\",
    \"sources\":[{\"n\":1,\"title\":\"GLib docs\",\"url\":\"https://docs.gtk.org/glib/\",
                 \"read\":true,\"cited\":true},
                {\"n\":2,\"title\":\"Unread\",\"url\":\"https://example.org/\",
                 \"read\":false,\"cited\":false}],
    \"dropped_citations\":0}"
  "A canned research document.")

(defconst cmacs-ai-research-tests--query-doc
  "{\"schema\":\"libresearch.query/1\",\"query\":\"search \\\"glib\\\" | fields title, url\",
    \"columns\":[{\"name\":\"title\",\"type\":\"STRING\"},{\"name\":\"url\",\"type\":\"STRING\"}],
    \"rows\":[{\"title\":\"GLib | GTK\",\"url\":\"https://docs.gtk.org/glib/\"},
             {\"title\":\"glib on GitLab\",\"url\":\"https://gitlab.gnome.org/GNOME/glib\"}],
    \"engines\":[{\"id\":\"duckduckgo\",\"state\":\"ok\"},{\"id\":\"brave\",\"state\":\"timeout\"}]}"
  "A canned LQL result document.")

(defconst cmacs-ai-research-tests--fetch-doc
  "{\"schema\":\"libresearch.fetch/1\",\"url\":\"https://example.org/\",\"title\":\"Example\",
    \"text\":\"Hello.\\n#+keyword that is not one\",\"truncated\":true}"
  "A canned fetch document.")

(defun cmacs-ai-research-tests--payload (kind json)
  "A success payload of KIND carrying JSON, as the C side builds it."
  (list :ok :kind kind :text "" :json json))

(defmacro cmacs-ai-research-tests--with-executor (var &rest body)
  "Bind VAR to a fresh tool executor around BODY, freeing it after."
  (declare (indent 1))
  `(let ((,var (cmacs-ai-tools-new)))
     (unwind-protect (progn ,@body)
       (cmacs-ai-tools-free ,var))))

;;;; web_search backend ---------------------------------------------------------

(ert-deftest cmacs-ai-research-search-provider-libresearch ()
  "`libresearch' registers web_search without contacting the server."
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  (cmacs-ai-research-tests--with-executor exec
    (should (eq t (cmacs-ai-tools-set-search-provider
                   exec 'libresearch nil "http://127.0.0.1:9")))
    (should (member "web_search" (cmacs-ai-tools-list exec)))))

(ert-deftest cmacs-ai-research-search-provider-libresearch-default-endpoint ()
  "With no endpoint, `libresearch' still registers (ai-glib's default URL)."
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  (cmacs-ai-research-tests--with-executor exec
    (should (eq t (cmacs-ai-tools-set-search-provider exec 'libresearch)))
    (should (member "web_search" (cmacs-ai-tools-list exec)))))

(ert-deftest cmacs-ai-research-search-provider-endpoint-type-checked ()
  "A non-string ENDPOINT is a type error, not a silent default."
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  (cmacs-ai-research-tests--with-executor exec
    (should-error (cmacs-ai-tools-set-search-provider exec 'libresearch nil 8087)
                  :type 'wrong-type-argument)))

(ert-deftest cmacs-ai-research-set-search-provider-front-door ()
  "`cmacs-ai-set-search-provider' validates the choice before the primitive."
  (skip-unless (fboundp 'cmacs-ai-set-search-provider))
  (should (memq 'libresearch cmacs-ai-search-providers))
  (should-error (cmacs-ai-set-search-provider 0 'nope) :type 'user-error))

(ert-deftest cmacs-ai-research-set-search-provider-uses-url-and-token ()
  "The front door hands `libresearch' the configured URL and token."
  (skip-unless (fboundp 'cmacs-ai-set-search-provider))
  (let ((seen nil)
        (cmacs-ai-libresearch-url "http://lr.test:8087")
        (cmacs-ai-libresearch-token-function (lambda (_url) "tok")))
    (cl-letf (((symbol-function 'cmacs-ai-tools-set-search-provider)
               (lambda (&rest args) (setq seen args) t)))
      (cmacs-ai-set-search-provider 7 'libresearch))
    (should (equal seen '(7 libresearch "tok" "http://lr.test:8087")))))

;;;; Primitive argument checking ------------------------------------------------

(ert-deftest cmacs-ai-research-primitives-check-arguments ()
  "Bad arguments signal before any request or thread is started."
  (skip-unless (fboundp 'cmacs-ai--libresearch-research))
  (should-error (cmacs-ai--libresearch-research "" nil))
  (should-error (cmacs-ai--libresearch-research 42 nil)
                :type 'wrong-type-argument)
  (should-error (cmacs-ai--libresearch-research "q" "not a function")
                :type 'wrong-type-argument)
  (should-error (cmacs-ai--libresearch-research "q" nil '(:pages 21))
                :type 'args-out-of-range)
  (should-error (cmacs-ai--libresearch-research "q" nil 'not-a-plist)
                :type 'wrong-type-argument)
  (should-error (cmacs-ai--libresearch-research "q" nil '(:endpoint 8087))
                :type 'wrong-type-argument)
  (should-error (cmacs-ai--libresearch-research "q" nil '(:timeout -1))
                :type 'wrong-type-argument)
  (should-error (cmacs-ai--libresearch-search "q" nil '(:category "books"))
                :type 'cmacs-ai-error)
  (should-error (cmacs-ai--libresearch-search "q" nil '(:count 101))
                :type 'args-out-of-range)
  (should-error (cmacs-ai--libresearch-search "q" nil '(:site 3))
                :type 'wrong-type-argument)
  (should-error (cmacs-ai--libresearch-fetch "https://e.org" nil '(:archive maybe))
                :type 'cmacs-ai-error)
  (should-error (cmacs-ai--libresearch-fetch "https://e.org" nil '(:max-chars 50))
                :type 'args-out-of-range)
  (should-error (cmacs-ai--libresearch-lql "" nil)))

(ert-deftest cmacs-ai-research-poll-unknown-id ()
  "Polling an id that was never issued is an error; cancelling it is nil."
  (skip-unless (fboundp 'cmacs-ai--libresearch-poll))
  (should-error (cmacs-ai--libresearch-poll 987654321) :type 'cmacs-ai-error)
  (should-not (cmacs-ai--libresearch-cancel 987654321)))

(ert-deftest cmacs-ai-research-default-endpoint ()
  "ai-glib's built-in endpoint is libresearchd's own default."
  (skip-unless (fboundp 'cmacs-ai--libresearch-default-endpoint))
  (should (equal (cmacs-ai--libresearch-default-endpoint)
                 "http://127.0.0.1:8087")))

;;;; ai-glib's text rendering of canned documents --------------------------------

(ert-deftest cmacs-ai-research-format-research ()
  "The research text carries the answer and the numbered sources."
  (skip-unless (fboundp 'cmacs-ai--libresearch-format))
  (let ((text (cmacs-ai--libresearch-format
               'research cmacs-ai-research-tests--research-doc)))
    (should (string-match-p "GLib is a utility library \\[1\\]" text))
    (should (string-match-p "Sources:" text))
    (should (string-match-p "\\[1\\] GLib docs -- https://docs.gtk.org/glib/" text))
    (should (string-match-p "not read" text))))

(ert-deftest cmacs-ai-research-format-query-and-cap ()
  "LQL text names every column per row, and MAX-ROWS caps it."
  (skip-unless (fboundp 'cmacs-ai--libresearch-format))
  (let ((all (cmacs-ai--libresearch-format
              'lql cmacs-ai-research-tests--query-doc))
        (one (cmacs-ai--libresearch-format
              'lql cmacs-ai-research-tests--query-doc 1)))
    (should (string-match-p "2 rows" all))
    (should (string-match-p "glib on GitLab" all))
    (should (string-match-p "brave (timeout)" all))
    (should-not (string-match-p "glib on GitLab" one))
    (should (string-match-p "1 more rows not shown" one))))

(ert-deftest cmacs-ai-research-format-rejects-bad-input ()
  "Unknown kinds and non-object JSON signal `cmacs-ai-error'."
  (skip-unless (fboundp 'cmacs-ai--libresearch-format))
  (should-error (cmacs-ai--libresearch-format 'nope "{}") :type 'cmacs-ai-error)
  (should-error (cmacs-ai--libresearch-format 'fetch "[1,2]") :type 'cmacs-ai-error)
  (should-error (cmacs-ai--libresearch-format 'fetch "{not json") :type 'cmacs-ai-error))

;;;; Org rendering (pure Elisp) -------------------------------------------------

(ert-deftest cmacs-ai-research-org-research-links-and-escapes ()
  "Sources become Org links; answer text cannot open a headline."
  (skip-unless (fboundp 'cmacs-ai-research-org-body))
  (let ((org (cmacs-ai-research-org-body
              (cmacs-ai-research-tests--payload
               'research cmacs-ai-research-tests--research-doc))))
    (should (string-match-p "^- \\[1\\] \\[\\[https://docs.gtk.org/glib/\\]\\[GLib docs\\]\\]" org))
    (should (string-match-p "/(not read, not cited)/" org))
    (should (string-match-p "^,\\* looks like a headline" org))
    (should-not (string-match-p "^\\*+ " org))))

(ert-deftest cmacs-ai-research-org-lql-table ()
  "LQL rows become an Org table with escaped pipes and a failed-engine note."
  (skip-unless (fboundp 'cmacs-ai-research-org-body))
  (let ((org (cmacs-ai-research-org-body
              (cmacs-ai-research-tests--payload
               'lql cmacs-ai-research-tests--query-doc))))
    (should (string-match-p "^| title | url |$" org))
    (should (string-match-p "GLib \\\\vert{} GTK" org))
    (should (string-match-p "brave (timeout)" org))
    (should-not (string-match-p "duckduckgo" org))))

(ert-deftest cmacs-ai-research-org-lql-explain ()
  "An explained query renders its plan, not a table."
  (skip-unless (fboundp 'cmacs-ai-research-org-body))
  (let ((org (cmacs-ai-research-org-body
              (cmacs-ai-research-tests--payload
               'lql "{\"query\":\"q\",\"explain\":\"search -> filter\"}"))))
    (should (string-match-p "#\\+begin_example\nsearch -> filter" org))
    (should-not (string-match-p "^|" org))))

(ert-deftest cmacs-ai-research-org-fetch-and-errors ()
  "A fetch notes truncation and escapes keywords; errors render too."
  (skip-unless (fboundp 'cmacs-ai-research-org-body))
  (let ((org (cmacs-ai-research-org-body
              (cmacs-ai-research-tests--payload
               'fetch cmacs-ai-research-tests--fetch-doc))))
    (should (string-match-p "truncated by the server" org))
    (should (string-match-p "^,#\\+keyword" org)))
  (should (string-match-p "boom" (cmacs-ai-research-org-body '(:error "boom"))))
  (should (string-match-p "Cancelled" (cmacs-ai-research-org-body '(:cancelled)))))

(ert-deftest cmacs-ai-research-slash-command-parser ()
  "The chat compose commands parse into request specs."
  (skip-unless (fboundp 'cmacs-ai-research-parse-command))
  (should (equal (cmacs-ai-research-parse-command "/research why?")
                 '(research "why?")))
  (should (equal (cmacs-ai-research-parse-command "/research!  why? ")
                 '(research "why?" :deep t)))
  (should (eq (car (cmacs-ai-research-parse-command "/fetch https://e.org"))
              'fetch))
  (should (eq (car (cmacs-ai-research-parse-command "/lql gtk | limit 3"))
              'lql))
  (should-not (cmacs-ai-research-parse-command "/research"))
  (should-not (cmacs-ai-research-parse-command "/researching x"))
  (should-not (cmacs-ai-research-parse-command "research x")))

;;;; CLI accounts ---------------------------------------------------------------

(ert-deftest cmacs-ai-research-cli-config-dir-refusals ()
  "An account directory for a CLI that cannot honour one, or for an HTTP
provider, is a `user-error' when the client is built."
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (let ((cmacs-ai-cli-config-dirs `((cursor . ,temporary-file-directory)
                                    (claude . ,temporary-file-directory))))
    (should-error (cmacs-ai-client-new 'cursor) :type 'user-error)
    (should-error (cmacs-ai-client-new 'claude) :type 'user-error)))

(ert-deftest cmacs-ai-research-cli-config-dir-applies ()
  "A supported CLI takes its directory, by exact name and by alias."
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (dolist (entry '((claude-code . claude-code) (codex . codex-cli)))
    (let* ((cmacs-ai-cli-config-dirs
            `((,(car entry) . ,temporary-file-directory)))
           (h (cmacs-ai-client-new (cdr entry))))
      (should (natnump h))
      (cmacs-ai-client-free h))))

;;;; End to end against a stub libresearchd -------------------------------------

(defun cmacs-ai-research-tests--stub-server (body requests)
  "Serve BODY as JSON to every HTTP request on a loopback port.
Each raw request is pushed onto the symbol REQUESTS.  Returns the
server process; its port is (process-contact PROC :service)."
  (make-network-process
   :name "cmacs-ai-research-stub" :server t :host "127.0.0.1" :service t
   :family 'ipv4 :coding 'binary :noquery t
   :filter
   (let ((pending (make-hash-table :test #'eq)))
     (lambda (proc chunk)
       (let ((acc (concat (gethash proc pending "") chunk)))
         (puthash proc acc pending)
         (when (string-search "\r\n\r\n" acc)
           (set requests (cons acc (symbol-value requests)))
           (let ((payload (encode-coding-string body 'utf-8)))
             (process-send-string
              proc
              (concat "HTTP/1.1 200 OK\r\n"
                      "Content-Type: application/json\r\n"
                      (format "Content-Length: %d\r\n" (length payload))
                      "Connection: close\r\n\r\n"
                      payload)))
           (run-at-time 0.2 nil (lambda ()
                                  (when (process-live-p proc)
                                    (delete-process proc))))))))))

(defun cmacs-ai-research-tests--lower-headers (s)
  "S with HTTP header names lower-cased, so a header match ignores case."
  (replace-regexp-in-string "^\\([A-Za-z-]+\\):"
                            (lambda (m) (downcase m)) s t))

(defvar cmacs-ai-research-tests--requests nil
  "Raw requests the stub server saw.")

(ert-deftest cmacs-ai-research-end-to-end-stub ()
  "A research request reaches the server with its token and comes back
rendered, while this Emacs serves the stub -- so the wait cannot be one
that blocks the Lisp thread's process I/O."
  (skip-unless (and (fboundp 'cmacs-ai--libresearch-research)
                    (fboundp 'cmacs-ai-research-sync)))
  (setq cmacs-ai-research-tests--requests nil)
  (let* ((server (cmacs-ai-research-tests--stub-server
                  cmacs-ai-research-tests--research-doc
                  'cmacs-ai-research-tests--requests))
         (port (process-contact server :service))
         (cmacs-ai-libresearch-url (format "http://127.0.0.1:%d" port))
         (cmacs-ai-libresearch-token-function (lambda (_url) "sekrit")))
    (unwind-protect
        (let ((payload (cmacs-ai-research-sync 'research "what is glib"
                                               :pages 3 :timeout 20)))
          (should (eq (car payload) :ok))
          (should (eq (plist-get (cdr payload) :kind) 'research))
          (should (string-match-p "GLib is a utility library"
                                  (plist-get (cdr payload) :text)))
          (should (string-match-p "\\[\\[https://docs.gtk.org/glib/\\]"
                                  (cmacs-ai-research-org-body payload)))
          (let ((req (car cmacs-ai-research-tests--requests)))
            (should req)
            (should (string-match-p "\\`GET /api/v1/research" req))
            (should (string-match-p "^authorization: Bearer sekrit"
                                    (cmacs-ai-research-tests--lower-headers req)))))
      (delete-process server))))

(ert-deftest cmacs-ai-research-unreachable-server-errors ()
  "A server nobody is listening on comes back as (:error ...), not a hang."
  (skip-unless (and (fboundp 'cmacs-ai--libresearch-fetch)
                    (fboundp 'cmacs-ai-research-sync)))
  (let ((cmacs-ai-libresearch-url "http://127.0.0.1:9")
        (cmacs-ai-libresearch-token-function #'ignore))
    (should (eq (car (cmacs-ai-research-sync 'fetch "https://example.org/"
                                             :timeout 10))
                :error))))

(provide 'cmacs-ai-research-tests)
;;; cmacs-ai-research-tests.el ends here
