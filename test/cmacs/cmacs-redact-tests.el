;;; cmacs-redact-tests.el --- ERT tests for the redaction table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-redact' is Elisp over the journal's filter engine, so all of
;; it runs here: rules are bound for the length of a test, and "who is
;; asking" is set by binding the same variables the advice and the RPC
;; dispatch bind.
;;
;; Every test runs with no filter files and no shipped default rules
;; unless it asks for them, so a rule in the developer's own ~/.config
;; never decides a result.
;;
;; The C half -- the MCP resources and the image-returning tools -- is
;; C that evaluates a Lisp form.  The Lisp functions those forms call
;; are tested here directly, and a source guard checks that each handler
;; still calls them.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'warnings)
(require 'cmacs-redact)
(require 'cmacs-ai-view)

(declare-function cmacs-gsurf-mcp-snapshot "cmacs-gsurf"
                  (file &optional full buffer))
(declare-function cmacs-gsurf-mcp-print-pdf "cmacs-gsurf"
                  (file &optional buffer))

(defmacro cmacs-redact-tests--with-rules (rules &rest body)
  "Run BODY with RULES as the whole rule set and the caller a model."
  (declare (indent 1) (debug t))
  `(let* ((cmacs-journal-filter-files nil)
          (cmacs-journal-default-filters nil)
          (cmacs-journal-filters ,rules)
          (cmacs-journal-filter--rules nil)
          (cmacs-journal-filter--loaded nil)
          (cmacs-journal-filter--error nil)
          (cmacs-journal-filter--signature nil)
          (cmacs-journal-filter-case-fold t)
          (cmacs-journal-filter-hash-key "test-key-0123456789abcdef0123456789")
          (cmacs-journal-filter-changed-functions nil)
          (cmacs-redact-mode t)
          (cmacs-redact-surfaces '(tool rpc prompt))
          (cmacs-redact-text-field-rules t)
          (cmacs-redact-resolve-projects nil)
          (cmacs-redact--as-model t)
          (cmacs-redact--in-tool-call nil)
          (cmacs-redact--pending nil)
          ;; Far in the future: the files are never re-checked mid-test.
          (cmacs-redact--last-check (+ (float-time) 3600.0))
          (inhibit-interaction nil)
          (warning-minimum-log-level :emergency)
          (warning-minimum-level :emergency))
     (cmacs-journal-filters-reload)
     ,@body))

(defmacro cmacs-redact-tests--with-buffer (spec &rest body)
  "Run BODY with a temporary buffer bound as SPEC says.
SPEC is (VAR NAME &optional FILE MODE)."
  (declare (indent 1) (debug t))
  (let ((var (nth 0 spec)))
    `(let ((,var (generate-new-buffer ,(nth 1 spec))))
       (unwind-protect
           (progn
             (with-current-buffer ,var
               ,@(when (nth 3 spec) `((funcall ,(nth 3 spec))))
               (setq buffer-file-name ,(nth 2 spec)))
             ,@body)
         (with-current-buffer ,var
           (setq buffer-file-name nil)
           (set-buffer-modified-p nil))
         (kill-buffer ,var)))))

(defconst cmacs-redact-tests--secret-re "zebra-crossing-[0-9]+"
  "A regexp no test output may ever contain: it is the rule itself.")

;;;; Windows

(ert-deftest cmacs-redact-test-an-excluded-window-is-nil ()
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "keepass")) :exclude t))
    (should-not (cmacs-redact-window "org.keepassxc.KeePassXC" "Vault"))
    (should (equal (cmacs-redact-window "foot" "~/src")
                   '("foot" . "~/src")))))

(ert-deftest cmacs-redact-test-a-window-is-matched-as-the-journal-records-it ()
  "A rule naming the journal's `focus' kind and a pid matches a window."
  (cmacs-redact-tests--with-rules
      '((:match ((:kind . "\\`focus\\'") (:pid . "\\`4242\\'")) :exclude t))
    (should-not (cmacs-redact-window "foot" "x" 4242))
    (should (cmacs-redact-window "foot" "x" 4243))
    (should (cmacs-redact-window "foot" "x"))))

(ert-deftest cmacs-redact-test-a-window-title-is-rewritten ()
  (cmacs-redact-tests--with-rules
      '((:match ((:title . "Invoice"))
         :replace ((:title "[0-9]\\{6,\\}" "***")))
        (:match ((:app . "bank")) :drop (:title))
        (:match ((:app . "slack")) :hash (:title)))
    (should (equal (cmacs-redact-window "evince" "Invoice 12345678.pdf")
                   '("evince" . "Invoice ***.pdf")))
    (should (equal (cmacs-redact-window "mybank" "Balance: 9") '("mybank")))
    (let ((hashed (cmacs-redact-window "slack" "#secret-channel")))
      (should (string-match-p "\\`#[0-9a-f]\\{12\\}\\'" (cdr hashed)))
      (should (equal hashed (cmacs-redact-window "slack" "#secret-channel"))))))

(ert-deftest cmacs-redact-test-hash-works-without-the-journal-key ()
  "With no journal key a hash is still a hash, not the text."
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "slack")) :hash (:title)))
    (let ((cmacs-journal-filter-hash-key nil)
          (cmacs-redact--session-key nil))
      (let ((title (cdr (cmacs-redact-window "slack" "general"))))
        (should (string-match-p "\\`#[0-9a-f]\\{12\\}\\'" title)))
      ;; And the journal's own key was not touched by asking.
      (should-not cmacs-journal-filter-hash-key))))

;;;; Buffers

(ert-deftest cmacs-redact-test-a-buffer-is-excluded-by-file-mode-or-name ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "\\.gpg\\'")) :exclude t)
        (:match ((:mode . "\\`text-mode\\'")) :exclude t)
        (:match ((:buffer . "\\`\\*vault")) :exclude t))
    (cmacs-redact-tests--with-buffer (b "keys" "/tmp/x/keys.gpg")
      (should (cmacs-redact-buffer-p b))
      (should (cmacs-redact-buffer-p (buffer-name b)))
      (should-not (cmacs-redact-buffer b)))
    (cmacs-redact-tests--with-buffer (b "notes" nil #'text-mode)
      (should (cmacs-redact-buffer-p b)))
    (cmacs-redact-tests--with-buffer (b "plain" "/tmp/x/plain.c")
      (should-not (cmacs-redact-buffer-p b))
      (should (equal (plist-get (cmacs-redact-buffer b) :buffer)
                     (buffer-name b))))
    ;; A name with no buffer behind it is still judged by the name.
    (should (cmacs-redact-buffer-p "*vault of things*"))
    (should-not (cmacs-redact-buffer-p "no-such-buffer-here"))))

(ert-deftest cmacs-redact-test-a-dired-or-indirect-buffer-has-its-file ()
  "A rule hiding a directory hides the Dired buffer showing it."
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "/hidden-dir/")) :exclude t))
    (let ((b (generate-new-buffer "hidden-dir")))
      (unwind-protect
          (progn
            (with-current-buffer b
              (setq major-mode 'dired-mode
                    default-directory "/tmp/hidden-dir/"))
            (should (cmacs-redact-buffer-p b)))
        (kill-buffer b)))
    (cmacs-redact-tests--with-buffer (base "base" "/tmp/hidden-dir/a.txt")
      (let ((indirect (make-indirect-buffer base "base<2>")))
        (unwind-protect
            (should (cmacs-redact-buffer-p indirect))
          (kill-buffer indirect))))))

(ert-deftest cmacs-redact-test-a-buffer-description-is-rewritten ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "/clients/"))
         :replace ((:file "/clients/[^/]+" "/clients/_")) :hash (:buffer)))
    (cmacs-redact-tests--with-buffer (b "acme-notes" "/tmp/clients/acme/n.org")
      (let ((shown (cmacs-redact-buffer b)))
        (should (equal (plist-get shown :file) "/tmp/clients/_/n.org"))
        (should (string-match-p "\\`#[0-9a-f]+\\'"
                                (plist-get shown :buffer)))))))

;;;; URLs, events

(ert-deftest cmacs-redact-test-a-url-is-excluded-or-rewritten ()
  (cmacs-redact-tests--with-rules
      '((:match ((:url . "bank\\.example")) :exclude t)
        (:match ((:url . "token=")) :replace ((:url "token=[^&]+" "token=_")))
        (:match ((:url . "intranet")) :drop (:url)))
    (should-not (cmacs-redact-url "https://bank.example/login"))
    (should (equal (cmacs-redact-url "https://a.example/?token=abc&x=1")
                   "https://a.example/?token=_&x=1"))
    (should-not (cmacs-redact-url "https://intranet.example/"))
    (should (equal (cmacs-redact-url "https://example.org/")
                   "https://example.org/"))))

(ert-deftest cmacs-redact-test-the-general-form-takes-any-field ()
  (cmacs-redact-tests--with-rules
      '((:match ((:project . "skunkworks")) :exclude t)
        (:match ((:kind . "agent")) :drop (:detail)))
    (should-not (cmacs-redact-event '(:kind buffer :project "skunkworks")))
    (let ((out (cmacs-redact-event '(:kind agent :title "t" :detail "d"))))
      (should (equal (plist-get out :title) "t"))
      (should-not (plist-get out :detail)))))

;;;; Free text

(ert-deftest cmacs-redact-test-text-rules-apply-to-free-text ()
  (cmacs-redact-tests--with-rules
      '((:match ((:text . "sk-[a-z0-9]+"))
         :replace ((:text "sk-[a-z0-9]+" "[key]")))
        (:match ((:text . "BEGIN PRIVATE KEY")) :exclude t)
        (:match ((:text . "\\`drop me")) :drop (:text)))
    (should (equal (cmacs-redact-text "export K=sk-abc123 ok")
                   "export K=[key] ok"))
    (should (equal (cmacs-redact-text "-----BEGIN PRIVATE KEY-----\nMIIE")
                   cmacs-redact-excluded-text))
    (should (equal (cmacs-redact-text "drop me please") ""))
    (should (equal (cmacs-redact-text "nothing to see") "nothing to see"))
    (should (equal (cmacs-redact-text "") ""))
    (should-not (cmacs-redact-text nil))))

(ert-deftest cmacs-redact-test-field-rules-reach-free-text ()
  "What a rule calls sensitive in a field is found in running text."
  (cmacs-redact-tests--with-rules
      '((:match ((:title . "Invoice"))
         :replace ((:title "[0-9]\\{6,\\}" "***")))
        (:match ((:project . "skunk[a-z]+")) :hash (:project))
        ;; Whole-field patterns mean nothing inside a text: skipped.
        (:match ((:url . "bank")) :replace ((:url ".*" "gone")))
        (:match ((:app . ".*")) :hash (:app)))
    (let ((out (cmacs-redact-text "acct 12345678 in skunkworks, twice: skunkworks")))
      (should (string-match-p "\\`acct \\*\\*\\* in #[0-9a-f]\\{12\\}, twice: #[0-9a-f]\\{12\\}\\'"
                              out))
      (should-not (string-match-p "gone" out)))
    ;; Off: only `text' rules touch free text.
    (let ((cmacs-redact-text-field-rules nil))
      (should (equal (cmacs-redact-text "acct 12345678") "acct 12345678")))))

(ert-deftest cmacs-redact-test-a-text-rule-is-not-applied-twice ()
  (cmacs-redact-tests--with-rules
      '((:match ((:text . "a")) :replace ((:text "a" "aa"))))
    (should (equal (cmacs-redact-text "banana") "baanaanaa"))))

(ert-deftest cmacs-redact-test-yaml-rules-know-the-text-field ()
  "The YAML form and the Elisp form of a `text' rule compile alike."
  (let ((yaml (cmacs-journal-filter--rules-from-yaml-data
               '((filters . (((match . ((text . "sk-\\w+")))
                              (replace . (((field . "text")
                                           (regexp . "sk-\\w+")
                                           (with . "[key]"))))))))
               "test"))
        (elisp (cmacs-journal-filter--rules-from-elisp
                '((:match ((:text . "sk-[[:alnum:]_]+"))
                   :replace ((:text "sk-[[:alnum:]_]+" "[key]"))))
                "test")))
    (should (equal yaml elisp))))

;;;; Fail closed

(ert-deftest cmacs-redact-test-unusable-rules-withhold-everything ()
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "\\(unbalanced")) :exclude t))
    (should-not (cmacs-journal-filter-ready-p))
    (should-not (cmacs-redact-ready-p))
    (should-not (cmacs-redact-window "foot" "~"))
    (should-not (cmacs-redact-url "https://example.org/"))
    (should-not (cmacs-redact-event '(:kind focus :app "foot")))
    (should (equal (cmacs-redact-text "hello")
                   "[withheld: redaction rules failed to load]"))
    (should (equal (cmacs-redact-text "") ""))
    (cmacs-redact-tests--with-buffer (b "plain" "/tmp/x/plain.c")
      (should (cmacs-redact-buffer-p b))
      (should-not (cmacs-redact-buffer b))
      (should (cmacs-redact-file-p "/tmp/x/plain.c"))
      (should (cmacs-redact-capture-refused-p 'buffer b))
      (should (cmacs-redact-capture-refused-p 'desktop))
      (should-error (cmacs-redact-resource-guard "buffer" (buffer-name b)))
      (should-error (cmacs-redact-resource-guard "variable" "load-path")))))

(ert-deftest cmacs-redact-test-rules-load-without-the-journal-mode ()
  "First use loads the rule set; the journal does not have to be on."
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "keepass")) :exclude t))
    (setq cmacs-journal-filter--loaded nil
          cmacs-journal-filter--rules nil)
    (let ((cmacs-journal-mode nil))
      (should-not (cmacs-redact-window "keepassxc" "Vault"))
      (should (cmacs-journal-filter-ready-p)))))

(ert-deftest cmacs-redact-test-a-failed-load-is-not-retried-per-call ()
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "\\(unbalanced")) :exclude t))
    (let ((loads 0))
      (cl-letf (((symbol-function 'cmacs-journal-filters-reload)
                 (lambda (&rest _) (setq loads (1+ loads)) nil)))
        (dotimes (_ 5) (cmacs-redact-window "a" "b"))
        (should (= loads 0))))))

;;;; Who is asking

(ert-deftest cmacs-redact-test-the-users-own-calls-are-not-redacted ()
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "keepass")) :exclude t)
        (:match ((:text . "secret")) :replace ((:text "secret" "_"))))
    (let ((cmacs-redact--as-model nil))
      (should-not (cmacs-redact-active-p))
      (should (equal (cmacs-redact-window "keepassxc" "Vault")
                     '("keepassxc" . "Vault")))
      (should (equal (cmacs-redact-text "a secret") "a secret"))
      (should (equal (cmacs-redact-url "u") "u"))
      (should-not (cmacs-redact-buffer-p "*scratch*"))
      (should-not (cmacs-redact-capture-refused-p 'no-such-kind))
      ;; Each signal on its own is enough.
      (let ((cmacs-redact--in-tool-call t))
        (should (cmacs-redact-active-p))
        (should-not (cmacs-redact-window "keepassxc" "Vault")))
      (let ((inhibit-interaction t))
        (should (cmacs-redact-active-p))
        (should (equal (cmacs-redact-text "a secret") "a _")))
      (cmacs-redact-as-model
        (should (cmacs-redact-active-p))))))

(ert-deftest cmacs-redact-test-surfaces-and-the-mode-switch-it-off ()
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "keepass")) :exclude t))
    (let ((cmacs-redact--as-model nil))
      (let ((cmacs-redact--in-tool-call t)
            (cmacs-redact-surfaces '(rpc prompt)))
        (should-not (cmacs-redact-active-p)))
      (let ((inhibit-interaction t)
            (cmacs-redact-surfaces '(tool prompt)))
        (should-not (cmacs-redact-active-p)))
      (let ((cmacs-redact-surfaces '(tool rpc)))
        (cmacs-redact-as-model (should-not (cmacs-redact-active-p))))
      (let ((cmacs-redact-mode nil)
            (cmacs-redact--in-tool-call t)
            (inhibit-interaction t))
        (should-not (cmacs-redact-active-p))
        (should (cmacs-redact-window "keepassxc" "Vault"))))))

(ert-deftest cmacs-redact-test-an-async-tool-call-counts-until-it-answers ()
  "The result of an async tool is made in a sentinel, outside the call."
  (cmacs-redact-tests--with-rules nil
    (let ((cmacs-redact--as-model nil)
          (saved nil) (answered nil) (inside nil))
      (cmacs-redact--around-async-tool-call
       (lambda (_wire _json callback &rest _)
         (setq inside (cmacs-redact-active-p)
               saved callback))
       "tool" "{}" (lambda (&rest results) (setq answered results)))
      (should inside)
      ;; The call has returned and nothing is bound, yet it is pending.
      (should-not cmacs-redact--in-tool-call)
      (should (cmacs-redact-active-p))
      (funcall saved 'ok "text")
      (should (equal answered '(ok "text")))
      (should-not (cmacs-redact-active-p))
      ;; A lost callback does not redact forever.
      (push (cons (list 'lost)
                  (- (float-time) cmacs-redact--pending-max-age 1.0))
            cmacs-redact--pending)
      (should-not (cmacs-redact-active-p)))))

(ert-deftest cmacs-redact-test-a-sync-tool-call-is-bound-for-its-extent ()
  (cmacs-redact-tests--with-rules nil
    (let ((cmacs-redact--as-model nil))
      (should (cmacs-redact--around-tool-call
               (lambda (&rest _) (cmacs-redact-active-p))))
      (should-not (cmacs-redact-active-p))
      (should-error (cmacs-redact--around-tool-call
                     (lambda (&rest _) (error "boom"))))
      (should-not (cmacs-redact-active-p)))))

;;;; The screen inventory

(defmacro cmacs-redact-tests--with-screen (buffers &rest body)
  "Show BUFFERS, each in a window, and run BODY in a last, extra window."
  (declare (indent 1) (debug t))
  `(let ((cmacs-ai-view--last nil)
         (chat (generate-new-buffer "chat")))
     (unwind-protect
         (save-window-excursion
           (ignore-errors (set-frame-height (selected-frame) 60))
           (delete-other-windows)
           (let ((first t))
             (dolist (buffer (append ,buffers (list chat)))
               (unless first (select-window (split-window-below)))
               (setq first nil)
               (switch-to-buffer buffer)))
           ,@body)
       (kill-buffer chat))))

(ert-deftest cmacs-redact-test-an-excluded-buffer-is-not-in-the-inventory ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "\\.gpg\\'")) :exclude t))
    (let ((cmacs-redact--as-model nil))  ; the view says so itself
      (cmacs-redact-tests--with-buffer (secret "keys" "/tmp/x/keys.gpg")
        (cmacs-redact-tests--with-buffer (plain "main" "/tmp/x/main.c")
          (cmacs-redact-tests--with-screen (list secret plain)
            (should (equal (cmacs-ai-view-buffers) (list plain)))
            (let ((inventory (cmacs-ai-view-inventory)))
              (should (string-match-p "main" inventory))
              (should-not (string-match-p "keys" inventory))
              (should-not (string-match-p "gpg" inventory))
              ;; Not counted either: nothing says a buffer is missing.
              (should-not (string-match-p "more visible" inventory)))
            (should-not (string-match-p "keys" (cmacs-ai-view-report)))
            ;; An explicit list does not get an excluded buffer through.
            (with-current-buffer secret (insert "hunter2"))
            (should-not (cmacs-ai-view-context (list secret)))
            ;; With the mode off the buffer is back.
            (let ((cmacs-redact-mode nil))
              (should (memq secret (cmacs-ai-view-buffers))))))))))

(ert-deftest cmacs-redact-test-the-inventory-prints-rewritten-names ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "/clients/"))
         :replace ((:file "/clients/[^/]+" "/clients/_")
                   (:buffer "acme" "client"))))
    (let ((cmacs-redact--as-model nil))
      (cmacs-redact-tests--with-buffer (b "acme-notes" "/tmp/clients/acme/n.org")
        (cmacs-redact-tests--with-screen (list b)
          (let ((inventory (cmacs-ai-view-inventory)))
            (should (string-match-p "client-notes" inventory))
            (should (string-match-p "/tmp/clients/_/n.org" inventory))
            (should-not (string-match-p "acme" inventory))))))))

(ert-deftest cmacs-redact-test-the-last-buffer-fallback-is-checked-too ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "\\.gpg\\'")) :exclude t))
    (let ((cmacs-redact--as-model nil))
      (cmacs-redact-tests--with-buffer (secret "keys" "/tmp/x/keys.gpg")
        (save-window-excursion
          (delete-other-windows)
          (let ((cmacs-ai-view--last secret))
            (should-not (cmacs-ai-view-buffers))
            (should-not (cmacs-ai-view-inventory))))))))

(ert-deftest cmacs-redact-test-inlined-text-goes-through-the-text-rules ()
  (skip-unless (require 'cmacs-ai-target nil t))
  (cmacs-redact-tests--with-rules
      '((:match ((:text . "sk-[a-z0-9]+"))
         :replace ((:text "sk-[a-z0-9]+" "[key]"))))
    (let ((cmacs-redact--as-model nil))
      (cmacs-redact-tests--with-buffer (b "env" "/tmp/x/env.txt")
        (with-current-buffer b (insert "TOKEN=sk-abc123\n"))
        (let ((context (cmacs-ai-view-context (list b))))
          (should (stringp context))
          (should (string-match-p "TOKEN=\\[key\\]" context))
          (should-not (string-match-p "sk-abc123" context)))))))

(ert-deftest cmacs-redact-test-the-view-shows-nothing-when-rules-fail ()
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "\\(unbalanced")) :exclude t))
    (let ((cmacs-redact--as-model nil))
      (cmacs-redact-tests--with-buffer (plain "main" "/tmp/x/main.c")
        (cmacs-redact-tests--with-screen (list plain)
          (should-not (cmacs-ai-view-inventory)))))))

;;;; Captures and resources

(ert-deftest cmacs-redact-test-a-visible-excluded-buffer-blocks-a-capture ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "\\.gpg\\'")) :exclude t))
    (cmacs-redact-tests--with-buffer (secret "keys" "/tmp/x/keys.gpg")
      (cmacs-redact-tests--with-buffer (plain "main" "/tmp/x/main.c")
        (should (cmacs-redact-capture-refused-p 'buffer secret))
        (should-not (cmacs-redact-capture-refused-p 'buffer plain))
        (should (cmacs-redact-capture-refused-p 'buffer "no-such-buffer"))
        (cmacs-redact-tests--with-screen (list plain)
          (should-not (cmacs-redact-capture-refused-p 'frame))
          (should-not (cmacs-redact-capture-guard 'frame)))
        (cmacs-redact-tests--with-screen (list plain secret)
          (should (cmacs-redact-capture-refused-p 'frame))
          (should (cmacs-redact-capture-refused-p 'desktop))
          (should (equal (cadr (should-error
                                (cmacs-redact-capture-guard 'desktop)))
                         cmacs-redact-capture-refusal)))
        ;; An unknown kind of capture is never allowed through.
        (should (cmacs-redact-capture-refused-p 'hologram))))))

(ert-deftest cmacs-redact-test-only-windows-on-a-shown-tag-block-the-desktop ()
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "keepass")) :exclude t))
    (save-window-excursion
      (delete-other-windows)
      (let ((clients '((a . ((app-id . "foot") (title . "sh") (tags . 1)))
                       (b . ((app-id . "keepassxc") (title . "Vault")
                             (tags . 4))))))
        (cl-letf (((symbol-function 'gowl-list-clients)
                   (lambda (&rest _) (mapcar #'car clients)))
                  ((symbol-function 'gowl-client-info)
                   (lambda (client &rest _) (alist-get client clients)))
                  ((symbol-function 'gowl-client-pid) (lambda (&rest _) 7))
                  ((symbol-function 'gowl-client-sticky-p) #'ignore)
                  ((symbol-function 'gowl-list-monitors)
                   (lambda (&rest _) '(m)))
                  ((symbol-function 'gowl-monitor-info)
                   (lambda (&rest _) '((tags . 1))))
                  ((symbol-function 'gowl-focused-client)
                   (lambda (&rest _) 'a)))
          ;; The password manager is on tag 3; tag 1 is showing.
          (should-not (cmacs-redact-capture-refused-p 'desktop))
          (should-not (cmacs-redact-capture-refused-p 'window))
          (should (cmacs-redact-capture-refused-p 'client 'b))
          (should-not (cmacs-redact-capture-refused-p 'client 'a))
          (cl-letf (((symbol-function 'gowl-monitor-info)
                     (lambda (&rest _) '((tags . 5)))))
            (should (cmacs-redact-capture-refused-p 'desktop)))
          ;; Tags that cannot be read: every window counts as on screen.
          (cl-letf (((symbol-function 'gowl-list-monitors)
                     (lambda (&rest _) (error "no compositor"))))
            (should (cmacs-redact-capture-refused-p 'desktop)))
          ;; A window that cannot be read is not shown.
          (cl-letf (((symbol-function 'gowl-client-info)
                     (lambda (&rest _) (error "gone"))))
            (should (cmacs-redact-capture-refused-p 'client 'a))))))))

(ert-deftest cmacs-redact-test-resources-are-refused-by-the-same-rules ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "/hidden-dir/")) :exclude t)
        (:match ((:buffer . "\\`\\*Messages\\*\\'")) :exclude t))
    (cmacs-redact-tests--with-buffer (secret "keys" "/tmp/hidden-dir/keys")
      (should-error (cmacs-redact-resource-guard "buffer" (buffer-name secret)))
      (should-error (cmacs-redact-resource-guard "file" "/tmp/hidden-dir/keys"))
      (should-error (cmacs-redact-resource-guard "file" "/tmp/hidden-dir/other"))
      (should-error (cmacs-redact-resource-guard "messages"))
      (should-error (cmacs-redact-resource-guard "hologram" "x"))
      (should-not (cmacs-redact-resource-guard "file" "/tmp/elsewhere/a"))
      (should-not (cmacs-redact-resource-guard "buffer" "*scratch*"))
      (should-not (cmacs-redact-resource-guard "variable" "load-path"))
      (should-not (cmacs-redact-resource-guard "process" "no-such-process")))))

(ert-deftest cmacs-redact-test-a-link-into-a-hidden-directory-is-hidden ()
  (cmacs-redact-tests--with-rules
      '((:match ((:file . "/hidden-dir/")) :exclude t))
    (let* ((root (file-truename (make-temp-file "cmacs-redact-test" t)))
           (dir (expand-file-name "hidden-dir" root))
           (target (expand-file-name "id" dir))
           (link (expand-file-name "innocent.txt" root)))
      (unwind-protect
          (progn
            (make-directory dir)
            (write-region "x" nil target nil 'silent)
            (make-symbolic-link target link)
            (should (cmacs-redact-file-p link))
            (should-not (cmacs-redact-file-p
                         (expand-file-name "other.txt" root))))
        (delete-directory root t)))))

;;;; Never which rule

(ert-deftest cmacs-redact-test-nothing-reveals-the-rule ()
  "No result, error or report carries the text of the rule that matched."
  (cmacs-redact-tests--with-rules
      `((:match ((:title . ,cmacs-redact-tests--secret-re)) :exclude t)
        (:match ((:file . ,cmacs-redact-tests--secret-re)) :exclude t)
        (:match ((:text . ,cmacs-redact-tests--secret-re))
         :replace ((:text ,cmacs-redact-tests--secret-re "_"))))
    (let ((leak (regexp-quote cmacs-redact-tests--secret-re))
          (seen nil))
      (cmacs-redact-tests--with-buffer (b "x" "/tmp/zebra-crossing-7/f")
        (push (format "%S" (cmacs-redact-window "a" "zebra-crossing-42")) seen)
        (push (format "%S" (cmacs-redact-buffer b)) seen)
        (push (cmacs-redact-text "see zebra-crossing-9") seen)
        (push (error-message-string
               (should-error (cmacs-redact-capture-guard 'buffer b)))
              seen)
        (push (error-message-string
               (should-error
                (cmacs-redact-resource-guard "buffer" (buffer-name b))))
              seen)
        (save-window-excursion
          (cmacs-redact-test (list :kind 'focus :app "a"
                                   :title "zebra-crossing-42")
                             "see zebra-crossing-9")
          (push (with-current-buffer "*cmacs-redact-test*" (buffer-string))
                seen)
          (kill-buffer "*cmacs-redact-test*")))
      (dolist (text seen)
        (should-not (string-match-p leak text))
        (should-not (string-match-p "rule [0-9]" text)))
      ;; The two refusals read the same whatever matched.
      (should (member cmacs-redact-capture-refusal seen)))))

(ert-deftest cmacs-redact-test-the-check-command-ignores-who-is-asking ()
  "`cmacs-redact-test' shows the model's view from the user's own command."
  (cmacs-redact-tests--with-rules
      '((:match ((:app . "keepass")) :exclude t)
        (:match ((:text . "secret")) :replace ((:text "secret" "_"))))
    (let ((cmacs-redact--as-model nil))
      (save-window-excursion
        (cmacs-redact-test '(:kind focus :app "keepassxc" :title "Vault")
                           "a secret")
        (with-current-buffer "*cmacs-redact-test*"
          (should (string-match-p "nothing: it is not listed"
                                  (buffer-string)))
          (should (string-match-p "^  a _$" (buffer-string))))
        (kill-buffer "*cmacs-redact-test*")))))

;;;; The C callers still call

(ert-deftest cmacs-redact-test-gsurf-captures-ask-in-lisp ()
  "A page snapshot or PDF asks in the Lisp both the C and Lisp tools reach."
  (skip-unless (locate-library "cmacs-gsurf"))
  (require 'cmacs-gsurf)
  (cmacs-redact-tests--with-rules
      '((:match ((:buffer . "\\`private-page")) :exclude t))
    (let ((captured nil)
          (page (generate-new-buffer "private-page"))
          (other (generate-new-buffer "public-page")))
      (unwind-protect
          (cl-letf (((symbol-function 'cmacs-gsurf-snapshot)
                     (lambda (&rest _) (setq captured t)))
                    ((symbol-function 'cmacs-gsurf-print-to-pdf)
                     (lambda (&rest _) (setq captured t))))
            (should-error (cmacs-gsurf-mcp-snapshot "/tmp/x.png" nil
                                                    (buffer-name page)))
            (should-error (cmacs-gsurf-mcp-print-pdf "/tmp/x.pdf"
                                                     (buffer-name page)))
            (should-not captured)
            (cmacs-gsurf-mcp-snapshot "/tmp/x.png" nil (buffer-name other))
            (should captured))
        (kill-buffer page)
        (kill-buffer other)))))

(defconst cmacs-redact-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name
                                 default-directory)))
  "The top of the source tree, found when this file is loaded.
At run time `load-file-name' is nil, which is how a guard like the two
below ends up skipped in every run without anyone noticing.")

(defun cmacs-redact-tests--c-function (file name)
  "The text of the C function NAME in FILE under cmacs/mcp/, or nil."
  (let ((path (expand-file-name (concat "cmacs/mcp/" file)
                                cmacs-redact-tests--root)))
    (when (file-readable-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (when (re-search-forward (concat "^" (regexp-quote name) " (") nil t)
          (let ((start (line-beginning-position)))
            (when (re-search-forward "^}" nil t)
              (buffer-substring-no-properties start (point)))))))))

(ert-deftest cmacs-redact-test-image-handlers-ask-before-capturing ()
  "Every MCP handler that returns a picture of the screen asks first."
  (pcase-dolist (`(,file ,function)
                 '(("cmacs-mcp-tools-gowl.c" "handle_gowl_screenshot")
                   ("cmacs-mcp-tools-shell.c" "handle_video_snapshot")
                   ("cmacs-mcp-tools-lrgterm.c" "handle_dump_screen")
                   ("cmacs-mcp-resources.c" "handle_screenshot_resource")))
    (let ((body (cmacs-redact-tests--c-function file function)))
      (skip-unless body)
      (ert-info ((format "%s in %s" function file))
        (should (string-match-p "(require 'cmacs-redact)" body))
        (should (string-match-p "cmacs-redact-capture-guard" body))))))

(ert-deftest cmacs-redact-test-resource-handlers-ask-before-reading ()
  "Every MCP resource that reads a buffer, a file or a value asks first."
  (pcase-dolist (`(,function ,kind)
                 '(("handle_buffer_resource" "buffer")
                   ("handle_file_resource" "file")
                   ("handle_messages_resource" "messages")
                   ("handle_variable_resource" "variable")
                   ("handle_process_resource" "process")))
    (let ((body (cmacs-redact-tests--c-function "cmacs-mcp-resources.c"
                                                function)))
      (skip-unless body)
      (ert-info (function)
        (should (string-match-p
                 (format "resource_allowed (\"%s\"" kind) body))
        ;; And asks before it reads: the guard is the first call.
        (should (< (string-match "resource_allowed" body)
                   (or (string-match "cmacs_dispatch_eval\\|g_file_get_contents"
                                     body)
                       most-positive-fixnum))))))
  (let ((guard (cmacs-redact-tests--c-function "cmacs-mcp-resources.c"
                                               "resource_allowed")))
    (skip-unless guard)
    (should (string-match-p "cmacs-redact-resource-guard" guard))
    (should (string-match-p "cmacs_dispatch_lisp_escape" guard))
    (should-not (string-match-p "g_strescape (" guard))))

(provide 'cmacs-redact-tests)

;;; cmacs-redact-tests.el ends here
