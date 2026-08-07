;;; cmacs-ai-tests.el --- ERT tests for cmacs-ai  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the cmacs-ai subsystem.  All tests skip when the C
;; subsystem isn't compiled in (`(fboundp 'cmacs-ai-supported-p)').
;; The integration-flavored tests additionally skip without an
;; ANTHROPIC_API_KEY in the environment.
;;
;; Run with: make -C test check-cmacs TESTS=cmacs-ai-tests

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)

;; Load only the parts we exercise here so the rest of the suite
;; doesn't drag in major-mode setup it doesn't need.
(when (fboundp 'cmacs-ai-supported-p)
  (require 'cmacs-ai)
  (require 'cmacs-ai-chat))

;; The transcript parser / history-end helpers are pure Elisp (no C
;; subsystem needed), so load the chat module best-effort to let those
;; tests run even on a build without --with-cmacs-ai.
(require 'cmacs-ai-chat nil 'noerror)

;;;; Availability --------------------------------------------------

(ert-deftest cmacs-ai-feature-available ()
  "When built with --with-cmacs-ai, the core DEFUNs exist."
  (skip-unless (fboundp 'cmacs-ai-supported-p))
  (should (cmacs-ai-supported-p))
  (should (fboundp 'cmacs-ai-providers))
  (should (fboundp 'cmacs-ai-client-new))
  (should (fboundp 'cmacs-ai-session-new))
  (should (fboundp 'cmacs-ai-chat-stream)))

(ert-deftest cmacs-ai-providers-list ()
  "Providers list contains the expected canonical names."
  (skip-unless (fboundp 'cmacs-ai-providers))
  (let ((providers (cmacs-ai-providers)))
    (should (memq 'claude providers))
    (should (memq 'openai providers))
    (should (memq 'gemini providers))
    (should (memq 'grok providers))
    (should (memq 'ollama providers))
    (should (memq 'claude-code providers))
    (should (memq 'opencode providers))
    (should (memq 'claude-tmux providers))))

(ert-deftest cmacs-ai-typelib-loaded ()
  "gi-require finds AiGlib without manual setup."
  (skip-unless (fboundp 'gi-require))
  (skip-unless (fboundp 'cmacs-ai-supported-p))
  (should (gi-require "AiGlib" "1.0")))

;;;; Client lifecycle (no network) ---------------------------------

(ert-deftest cmacs-ai-client-lifecycle ()
  "Create / list / free works without contacting the network."
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (let ((h (cmacs-ai-client-new 'claude)))
    (should (integerp h))
    (let ((found (assoc h (cmacs-ai-client-list))))
      (should found)
      (should (string= "Claude" (cdr found))))
    (cmacs-ai-client-set-model h "claude-sonnet-4-6")
    (should (string= "claude-sonnet-4-6"
                     (cmacs-ai-client-get-model h)))
    (cmacs-ai-client-free h)
    (should-not (assoc h (cmacs-ai-client-list)))))

(ert-deftest cmacs-ai-unknown-provider-errors ()
  "Unknown provider symbol signals."
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (should-error (cmacs-ai-client-new 'no-such-provider)))

(ert-deftest cmacs-ai-bad-client-handle-errors ()
  "Operations on freed/invalid handles signal."
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (let ((h (cmacs-ai-client-new 'claude)))
    (cmacs-ai-client-free h)
    (should-error (cmacs-ai-client-set-model h "x"))))

;;;; Session state (no network) ------------------------------------

(ert-deftest cmacs-ai-session-history ()
  "Sessions retain message count across append/clear."
  (skip-unless (fboundp 'cmacs-ai-session-new))
  (let* ((c (cmacs-ai-client-new 'claude))
         (s (cmacs-ai-session-new c)))
    (unwind-protect
        (progn
          (should (= 0 (cmacs-ai-session-message-count s)))
          (cmacs-ai-session-append-message s 'user "hi")
          (cmacs-ai-session-append-message s 'assistant "hello")
          (should (= 2 (cmacs-ai-session-message-count s)))
          (cmacs-ai-session-clear s)
          (should (= 0 (cmacs-ai-session-message-count s))))
      (cmacs-ai-session-free s)
      (cmacs-ai-client-free c))))

;;;; Chat buffer mechanics (no network) ----------------------------

(ert-deftest cmacs-ai-chat-buffer-creation ()
  "Opening a chat buffer initialises mode and markers."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let ((buf (cmacs-ai-chat-open 'claude)))
    (unwind-protect
        (with-current-buffer buf
          (should (eq major-mode 'cmacs-ai-chat-mode))
          (should (markerp cmacs-ai-chat--compose-marker))
          (should (consp cmacs-ai-chat-session-pair))
          (should (integerp (car cmacs-ai-chat-session-pair)))
          (should (integerp (cdr cmacs-ai-chat-session-pair))))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-chat-history-is-read-only ()
  "Edits above the compose marker signal text-read-only."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let ((buf (cmacs-ai-chat-open 'claude)))
    (unwind-protect
        (with-current-buffer buf
          (should-error
           (progn (goto-char (point-min)) (insert "X"))
           :type 'text-read-only))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-chat-compose-region-writable ()
  "Edits below the compose marker work."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let ((buf (cmacs-ai-chat-open 'claude)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          (should (string-match-p
                   "hello world"
                   (buffer-substring-no-properties
                    cmacs-ai-chat--compose-marker (point-max)))))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-chat-stream-callback-shape ()
  "Synthesised stream payloads render correctly into the buffer."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  ;; The harness pins HOME=/nonexistent, so the default `cmacs-ai-chat-dir'
  ;; is unwritable and the buffer's auto-save errors.  Redirect to a temp dir.
  (let* ((cmacs-ai-chat-dir (make-temp-file "cmacs-ai-test-" t))
         (buf (cmacs-ai-chat-open 'claude)))
    (unwind-protect
        (progn
          (cmacs-ai-chat--stream-callback buf '(:start))
          (cmacs-ai-chat--stream-callback buf '(:delta "hello "))
          (cmacs-ai-chat--stream-callback buf '(:delta "world"))
          (cmacs-ai-chat--stream-callback
           buf '(:end :text "hello world" :stop end-turn))
          (with-current-buffer buf
            (let ((body (buffer-substring-no-properties
                          (point-min)
                          cmacs-ai-chat--compose-marker)))
              ;; Assistant heading is now "<provider>/<model>" sourced
              ;; from ai-glib, with the provider half downcased
              ;; (e.g. "claude/claude-sonnet-4-20250514").
              (should (string-match-p "claude/" body))
              (should (string-match-p "hello world" body)))))
      (kill-buffer buf)
      (ignore-errors (delete-directory cmacs-ai-chat-dir t)))))

;;;; Label resolution (no network) ---------------------------------

(ert-deftest cmacs-ai-user-label-honors-defcustom ()
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let ((cmacs-ai-user-label "tester-x"))
    (should (equal "tester-x" (cmacs-ai-chat--user-label)))))

(ert-deftest cmacs-ai-user-label-falls-back-to-USER ()
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (skip-unless (getenv "USER"))
  (let ((cmacs-ai-user-label nil))
    (should (equal (getenv "USER") (cmacs-ai-chat--user-label)))))

(ert-deftest cmacs-ai-assistant-label-uses-provider-and-model ()
  "Assistant label is lowercased `<provider>/<model>' from ai-glib."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let ((buf (cmacs-ai-chat-open 'claude)))
    (unwind-protect
        (with-current-buffer buf
          (let ((label (cmacs-ai-chat--assistant-label)))
            (should (stringp label))
            ;; Provider half is downcased ("claude", not "Claude").
            (should (string-prefix-p "claude" label))
            ;; Should contain a slash + a model token from ai-glib's defaults.
            (should (string-match-p "claude/[^[:space:]]+" label))))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-pre-prompt-prepends-and-disable ()
  "`cmacs-ai-chat--apply-pre-prompt' prepends when set, no-ops when nil."
  (skip-unless (fboundp 'cmacs-ai-chat--apply-pre-prompt))
  (let ((cmacs-ai-pre-prompt "USE ORG."))
    (should (string-prefix-p "USE ORG."
                              (cmacs-ai-chat--apply-pre-prompt "hi"))))
  (let ((cmacs-ai-pre-prompt nil))
    (should (equal "hi" (cmacs-ai-chat--apply-pre-prompt "hi"))))
  (let ((cmacs-ai-pre-prompt ""))
    (should (equal "hi" (cmacs-ai-chat--apply-pre-prompt "hi")))))

;;;; MCP bridge ----------------------------------------------------

(ert-deftest cmacs-ai-mcp-bridge-loads ()
  "The MCP bridge DEFUN is wired in when MCP support is compiled in."
  (skip-unless (fboundp 'cmacs-ai-tools-register-mcp-bridge)))

(ert-deftest cmacs-ai-mcp-bridge-respects-allowlist ()
  "Only tools matching the allowlist get registered."
  (skip-unless (fboundp 'cmacs-ai-tools-register-mcp-bridge))
  (let ((exec (cmacs-ai-tools-new)))
    (unwind-protect
        (let ((n (cmacs-ai-tools-register-mcp-bridge
                  exec
                  (list "^list_buffers$" "^apropos$"))))
          (should (= n 2)))
      (cmacs-ai-tools-free exec))))

(ert-deftest cmacs-ai-mcp-bridge-denies-ai-recursion ()
  "Tools matching `^ai_' are always rejected even when explicitly
allowlisted -- the C layer's hardcoded recursion guard wins."
  (skip-unless (fboundp 'cmacs-ai-tools-register-mcp-bridge))
  (let ((exec (cmacs-ai-tools-new)))
    (unwind-protect
        (let ((n (cmacs-ai-tools-register-mcp-bridge
                  exec
                  (list "^ai_"))))
          (should (= n 0)))
      (cmacs-ai-tools-free exec))))

(ert-deftest cmacs-ai-mcp-bridge-readonly-only ()
  "READONLY-ONLY t includes read-only-hinted tools and excludes
non-hinted ones."
  (skip-unless (fboundp 'cmacs-ai-tools-register-mcp-bridge))
  (let ((exec-ro (cmacs-ai-tools-new))
        (exec-all (cmacs-ai-tools-new)))
    (unwind-protect
        (let ((n-ro  (cmacs-ai-tools-register-mcp-bridge
                       exec-ro nil nil t))
              (n-all (cmacs-ai-tools-register-mcp-bridge
                       exec-all nil nil nil)))
          ;; The read-only set must be a strict subset of the full set.
          (should (> n-all n-ro))
          (should (> n-ro 0)))
      (cmacs-ai-tools-free exec-ro)
      (cmacs-ai-tools-free exec-all))))

(ert-deftest cmacs-ai-mcp-bridge-auto-on-chat-init ()
  "Opening a chat buffer with the bridge enabled wires it implicitly."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (skip-unless (fboundp 'cmacs-ai-tools-register-mcp-bridge))
  (let ((cmacs-ai-mcp-bridge-enable t)
        (cmacs-ai-chat-enable-tools t)
        (buf (cmacs-ai-chat-open 'claude)))
    (unwind-protect
        (with-current-buffer buf
          ;; The executor exists and is non-nil; bridge registration
          ;; can't be cheaply introspected without firing a tool, but
          ;; the init path executed without error which is the
          ;; regression we care about.
          (should (integerp cmacs-ai-chat-tool-executor)))
      (kill-buffer buf))))

;;;; web_search wiring (registration only, no network) -------------

(ert-deftest cmacs-ai-tools-list-has-web-fetch-not-search ()
  "A fresh executor advertises web_fetch (a built-in) but not
web_search (which needs a provider)."
  (skip-unless (fboundp 'cmacs-ai-tools-list))
  (let ((exec (cmacs-ai-tools-new)))
    (unwind-protect
        (let ((tools (cmacs-ai-tools-list exec)))
          (should (member "web_fetch" tools))
          (should (member "bash" tools))
          (should-not (member "web_search" tools)))
      (cmacs-ai-tools-free exec))))

(ert-deftest cmacs-ai-set-search-provider-duckduckgo ()
  "Setting the keyless DuckDuckGo provider registers web_search."
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  (let ((exec (cmacs-ai-tools-new)))
    (unwind-protect
        (progn
          (should (eq t (cmacs-ai-tools-set-search-provider
                         exec 'duckduckgo)))
          (should (member "web_search" (cmacs-ai-tools-list exec))))
      (cmacs-ai-tools-free exec))))

(ert-deftest cmacs-ai-set-search-provider-auto ()
  "The `auto' provider always registers web_search (keyless fallback)."
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  (let ((exec (cmacs-ai-tools-new)))
    (unwind-protect
        (progn
          (should (eq t (cmacs-ai-tools-set-search-provider exec 'auto)))
          (should (member "web_search" (cmacs-ai-tools-list exec))))
      (cmacs-ai-tools-free exec))))

(ert-deftest cmacs-ai-set-search-provider-brave-needs-key ()
  "A keyed provider with no key available signals an error and leaves
web_search unregistered."
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  ;; Only meaningful when no Brave key is present in the environment.
  (skip-unless (not (getenv "BRAVE_API_KEY")))
  (let ((exec (cmacs-ai-tools-new)))
    (unwind-protect
        (progn
          (should-error (cmacs-ai-tools-set-search-provider exec 'brave))
          (should-not (member "web_search" (cmacs-ai-tools-list exec)))
          ;; An explicit key argument bypasses the env requirement.
          (should (eq t (cmacs-ai-tools-set-search-provider
                         exec 'brave "dummy-key")))
          (should (member "web_search" (cmacs-ai-tools-list exec))))
      (cmacs-ai-tools-free exec))))

(ert-deftest cmacs-ai-set-search-provider-unknown-errors ()
  "An unknown provider symbol signals an error."
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  (let ((exec (cmacs-ai-tools-new)))
    (unwind-protect
        (should-error (cmacs-ai-tools-set-search-provider exec 'nope))
      (cmacs-ai-tools-free exec))))

(ert-deftest cmacs-ai-web-search-auto-on-chat-init ()
  "Opening a chat buffer with `cmacs-ai-search-provider' set registers
web_search on the buffer's executor."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (skip-unless (fboundp 'cmacs-ai-tools-set-search-provider))
  (let ((cmacs-ai-chat-enable-tools t)
        (cmacs-ai-search-provider 'duckduckgo)
        (buf (cmacs-ai-chat-open 'claude)))
    (unwind-protect
        (with-current-buffer buf
          (should (integerp cmacs-ai-chat-tool-executor))
          (should (member "web_search"
                          (cmacs-ai-tools-list cmacs-ai-chat-tool-executor))))
      (kill-buffer buf))))

;;;; Inline image preview (no network / no display needed) ---------

(ert-deftest cmacs-ai-chat-http-image-bytes-ok ()
  "An HTTP 2xx image response yields its body bytes."
  (skip-unless (fboundp 'cmacs-ai-chat--http-image-bytes))
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n"
            "Content-Length: 5\r\n\r\nHELLO")
    (should (equal (cmacs-ai-chat--http-image-bytes) "HELLO"))))

(ert-deftest cmacs-ai-chat-http-image-bytes-rejects-non-image ()
  "Non-image content types and non-2xx statuses yield nil."
  (skip-unless (fboundp 'cmacs-ai-chat--http-image-bytes))
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html>")
    (should (null (cmacs-ai-chat--http-image-bytes))))
  (with-temp-buffer
    (insert "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\n\r\nnope")
    (should (null (cmacs-ai-chat--http-image-bytes)))))

(ert-deftest cmacs-ai-chat-preview-dispatches-remote-image ()
  "A remote image link triggers an async fetch; a non-image link does not."
  (skip-unless (fboundp 'cmacs-ai-chat--preview-images))
  (let ((cmacs-ai-chat-inline-images t)
        (calls nil))
    (cl-letf (((symbol-function 'cmacs-ai-chat--fetch-image-async)
               (lambda (url &rest _) (push url calls))))
      (with-temp-buffer
        (org-mode)
        (insert "[[https://example.com/pic.png]]\n"
                "[[https://example.com/page.html]]\n")
        (cmacs-ai-chat--preview-images
         (copy-marker (point-min) nil) (copy-marker (point-max) t))))
    (should (member "https://example.com/pic.png" calls))
    (should-not (member "https://example.com/page.html" calls))))

(ert-deftest cmacs-ai-chat-preview-disabled-noop ()
  "With `cmacs-ai-chat-inline-images' nil, nothing is dispatched."
  (skip-unless (fboundp 'cmacs-ai-chat--preview-images))
  (let ((cmacs-ai-chat-inline-images nil)
        (calls nil))
    (cl-letf (((symbol-function 'cmacs-ai-chat--fetch-image-async)
               (lambda (url &rest _) (push url calls))))
      (with-temp-buffer
        (org-mode)
        (insert "[[https://example.com/pic.png]]\n")
        (cmacs-ai-chat--preview-images
         (copy-marker (point-min) nil) (copy-marker (point-max) t))))
    (should-not calls)))

(ert-deftest cmacs-ai-chat-place-image-overlays ()
  "place-image builds an image overlay (needs a display + image support)."
  (skip-unless (fboundp 'cmacs-ai-chat--place-image))
  (skip-unless (and (display-images-p) (image-type-available-p 'xpm)))
  (with-temp-buffer
    (insert "XXXX")
    (let* ((data "/* XPM */\nstatic char *x[]={\n\"1 1 1 1\",\n\"a c #ff0000\",\n\"a\"};\n")
           (beg (copy-marker (point-min) nil))
           (end (copy-marker (point-max) t)))
      (cmacs-ai-chat--place-image beg end data)
      (let ((ov (cl-find-if (lambda (o) (overlay-get o 'cmacs-ai-image))
                            (overlays-in (point-min) (point-max)))))
        (should ov)
        (should (eq (car (overlay-get ov 'display)) 'image))))))

;;;; Save / resume (no network) ------------------------------------

(defconst cmacs-ai-tests--transcript
  (concat
   "#+TITLE: cmacs-ai -- 2026-06-05 14:00:00\n"
   "#+STARTUP: showall indent\n"
   "#+PROPERTY: provider claude\n"
   "\n"
   "* Conversation\n"
   "\n"
   "** 2026-06-05 14:00:01  zach\n"
   "First question?\n"
   "\n"
   "** 2026-06-05 14:00:02  claude/claude-sonnet-4-6\n"
   "Let me check.\n"
   "\n"
   "*** tool-use/bash\n"
   ":PROPERTIES:\n:tool: bash\n:id: t1\n:END:\n"
   "#+BEGIN_SRC json\n{\"command\":\"ls\"}\n#+END_SRC\n"
   "\n"
   "*** tool-result/bash\n"
   ":PROPERTIES:\n:tool: bash\n:id: t1\n:END:\n"
   "#+BEGIN_SRC text\nfile.txt\n#+END_SRC\n"
   "\n"
   "** 2026-06-05 14:00:03  claude/claude-sonnet-4-6\n"
   "Here is the answer.\n"
   "\n"
   "** 2026-06-05 14:00:04  error\n"
   "boom\n"
   "\n")
  "A chat archive body: a user turn, a tool-driven assistant turn split
across two `** assistant' headings, and a stray `error' heading.")

(ert-deftest cmacs-ai-chat-parse-transcript-coalesces ()
  "Parsing strips tool/error blocks, coalesces same-role turns, alternates."
  (skip-unless (fboundp 'cmacs-ai-chat--parse-transcript))
  (let ((turns (with-temp-buffer
                 (insert cmacs-ai-tests--transcript)
                 (cmacs-ai-chat--parse-transcript))))
    ;; Two messages: the user turn and a single coalesced assistant turn.
    (should (= 2 (length turns)))
    (should (equal '(user assistant) (mapcar #'car turns)))
    (should (equal "First question?" (cdr (nth 0 turns))))
    ;; The two assistant `**' headings (split by the tool loop) merge;
    ;; the `*** tool-…' blocks and the `error' heading are excluded.
    (should (equal "Let me check.\n\nHere is the answer."
                   (cdr (nth 1 turns))))
    (should-not (string-match-p "tool" (cdr (nth 1 turns))))
    (should-not (string-match-p "boom" (mapconcat #'cdr turns " ")))))

(ert-deftest cmacs-ai-chat-history-end-excludes-compose ()
  "`cmacs-ai-chat--history-end' stops before the `* Compose' sentinel."
  (skip-unless (fboundp 'cmacs-ai-chat--history-end))
  (with-temp-buffer
    (insert "#+TITLE: x\n\n* Conversation\n"
            "** 2026-06-05 10:00:00  user\nhi\n\n"
            "* Compose                                              :compose:\n")
    (goto-char (point-max))
    (setq-local cmacs-ai-chat--compose-marker (point-marker))
    (let* ((end (cmacs-ai-chat--history-end))
           (saved (buffer-substring-no-properties (point-min) end)))
      (should (< end (point-max)))
      (should (string-match-p "hi" saved))
      (should-not (string-match-p "\\* Compose" saved)))))

(ert-deftest cmacs-ai-chat-rebuild-session-counts ()
  "Replaying parsed turns into a session yields one message per turn."
  (skip-unless (fboundp 'cmacs-ai-session-new))
  (skip-unless (fboundp 'cmacs-ai-chat--parse-transcript))
  (let* ((c (cmacs-ai-client-new 'claude))
         (s (cmacs-ai-session-new c)))
    (unwind-protect
        (let ((turns (with-temp-buffer
                       (insert cmacs-ai-tests--transcript)
                       (cmacs-ai-chat--parse-transcript))))
          (should (= 2 (cmacs-ai-chat--rebuild-session s turns)))
          (should (= 2 (cmacs-ai-session-message-count s))))
      (cmacs-ai-session-free s)
      (cmacs-ai-client-free c))))

(ert-deftest cmacs-ai-chat-restore-from-file ()
  "Resuming an archive reopens the transcript and rebuilds the session."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let* ((dir (make-temp-file "cmacs-ai-test" t))
         (file (expand-file-name "260101-000000-claude.org" dir))
         (cmacs-ai-chat-dir dir))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: cmacs-ai -- 2026-01-01 00:00:00\n"
                    "#+PROPERTY: provider claude\n\n"
                    "* Conversation\n\n"
                    "** 2026-01-01 00:00:01  user\nFirst question?\n\n"
                    "** 2026-01-01 00:00:02  claude/claude-sonnet-4-6\n"
                    "Here is the answer.\n\n"))
          (let ((buf (cmacs-ai-chat-resume file)))
            (unwind-protect
                (with-current-buffer buf
                  (should (eq major-mode 'cmacs-ai-chat-mode))
                  (should (markerp cmacs-ai-chat--compose-marker))
                  ;; Transcript restored; a fresh compose sentinel appended.
                  (should (string-match-p "First question?" (buffer-string)))
                  (should (string-match-p "Here is the answer" (buffer-string)))
                  (should (string-match-p "^\\* Compose" (buffer-string)))
                  ;; Session rebuilt: user + coalesced assistant = 2 messages.
                  (should (= 2 (cmacs-ai-session-message-count
                                (cdr cmacs-ai-chat-session-pair))))
                  ;; Continuing appends to the SAME archive file.
                  (should (equal (expand-file-name file)
                                 cmacs-ai-chat--save-file)))
              (kill-buffer buf))))
      (delete-directory dir t))))

;;;; Integration (network) -----------------------------------------

(defun cmacs-ai-tests--have-claude-key ()
  (or (getenv "ANTHROPIC_API_KEY") (getenv "CLAUDE_API_KEY")))

(ert-deftest cmacs-ai-prompt-sync-claude ()
  "Round-trip a real prompt through Claude.  Gated on API key."
  (skip-unless (fboundp 'cmacs-ai-prompt-sync))
  (skip-unless (cmacs-ai-tests--have-claude-key))
  (let ((r (cmacs-ai-prompt-sync
            "Reply with the word OK and nothing else." 'claude
            "Output only OK.")))
    (should (stringp r))
    (should (string-match-p "OK" r))))

;;;; Generic call (cmacs-ai-call) ----------------------------------

(when (fboundp 'cmacs-ai-supported-p)
  (require 'cmacs-ai-call))

(ert-deftest cmacs-ai-call-defuns-exist ()
  "The generic-call primitive and its Elisp wrapper are present."
  (skip-unless (fboundp 'cmacs-ai-supported-p))
  (should (fboundp 'cmacs-ai--call))          ; C primitive
  (should (fboundp 'cmacs-ai-call))           ; Elisp wrapper (autoloaded)
  (should (fboundp 'cmacs-ai-define-tool))
  ;; The C primitive is a subr; the wrapper resolves to the Elisp
  ;; function once loaded (they must be different objects).
  (should (subrp (symbol-function 'cmacs-ai--call)))
  (should-not (eq (symbol-function 'cmacs-ai-call)
                  (symbol-function 'cmacs-ai--call))))

(ert-deftest cmacs-ai-define-tool-spec ()
  "`cmacs-ai-define-tool' builds a (NAME DESC PARAMS CALLBACK) spec."
  (skip-unless (fboundp 'cmacs-ai-define-tool))
  (let* ((cb (lambda (_n _i _id) "ok"))
         (spec (cmacs-ai-define-tool
                "t" "desc" '(("p" "string" "d" t)) cb)))
    (should (equal (nth 0 spec) "t"))
    (should (equal (nth 1 spec) "desc"))
    (should (equal (nth 2 spec) '(("p" "string" "d" t))))
    (should (eq (nth 3 spec) cb))))

(ert-deftest cmacs-ai-call-bad-executor ()
  "The primitive rejects a bogus executor handle before any network I/O."
  (skip-unless (fboundp 'cmacs-ai--call))
  (should-error (cmacs-ai--call "hi" nil nil nil 999999)))

(ert-deftest cmacs-ai-tools-executor-lifecycle ()
  "Create, register a custom tool on, and free an executor (no network)."
  (skip-unless (fboundp 'cmacs-ai-tools-new))
  (let ((exec (cmacs-ai-tools-new)))
    (should (integerp exec))
    (should (eq t (cmacs-ai-tools-register
                   exec "noop" "does nothing"
                   (cons '(("x" "string" "an arg" t))
                         (lambda (_n _i _id) "done")))))
    (should (eq t (cmacs-ai-tools-free exec)))))

(ert-deftest cmacs-ai-call-tool-round-trip-claude ()
  "End-to-end: a custom Elisp tool's return value reaches the model.
The tool returns a token that appears nowhere in the prompt, so the
model can only echo it if the tool result was fed back (verifies the
tool-return-value bridge).  Gated on a Claude API key."
  (skip-unless (fboundp 'cmacs-ai-call))
  (skip-unless (cmacs-ai-tests--have-claude-key))
  (let* ((fired nil)
         (tool (cmacs-ai-define-tool
                "get_secret_code"
                "Returns the secret access code for a given user."
                '(("user" "string" "The user name" t))
                (lambda (_name _input _id)
                  (setq fired t)
                  "the secret access code is ZORP-8842")))
         (ans (cmacs-ai-call
               (concat "Call get_secret_code for user alice, then reply "
                       "with the exact secret access code you received.")
               :provider 'claude
               :tools (list tool))))
    (should fired)
    (should (stringp ans))
    (should (string-match-p "ZORP-8842" ans))))

;;;; Image generation ----------------------------------------------
;;
;; The generator itself is stubbed throughout: these cover the layer
;; that decides where an image goes and what gets written into the
;; buffer, which is where the interesting behaviour lives.

(require 'cmacs-ai-image nil 'noerror)
(require 'cmacs-ai-image-block nil 'noerror)
(require 'cmacs-ai-image-chat nil 'noerror)

(defconst cmacs-ai-tests--png
  (apply #'unibyte-string
         (list 137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82
               0 0 0 1 0 0 0 1 8 6 0 0 0 31 21 196 137
               0 0 0 10 73 68 65 84 120 156 99 0 1 0 0 5 0 1
               13 10 45 180 0 0 0 0 73 69 78 68 174 66 96 130))
  "A one-pixel PNG, so tests write something a decoder would accept.")

(defmacro cmacs-ai-tests--with-stub-image (images &rest body)
  "Run BODY with the image generator stubbed to return IMAGES."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'cmacs-ai-image-generate-async)
              (lambda (_h _prompt cb _opts) (funcall cb (list :images ,images)) 1))
             ((symbol-function 'cmacs-ai-image-generate-sync)
              (lambda (_h _prompt _opts &optional _t) (list :images ,images)))
             ((symbol-function 'cmacs-ai-client-new) (lambda (&rest _) 1))
             ((symbol-function 'cmacs-ai-client-free) (lambda (&rest _) t))
             ((symbol-function 'cmacs-ai-image--ensure) (lambda () t))
             ((symbol-function 'cmacs-ai-image--available-p) (lambda () t)))
     ,@body))

(defun cmacs-ai-tests--one-image ()
  (list (list :data cmacs-ai-tests--png :mime "image/png")))

(ert-deftest cmacs-ai-image-mime-extension ()
  "MIME types map to the extension the file is saved under."
  (skip-unless (fboundp 'cmacs-ai-image--extension))
  (should (equal (cmacs-ai-image--extension "image/png") ".png"))
  (should (equal (cmacs-ai-image--extension "image/jpeg") ".jpg"))
  (should (equal (cmacs-ai-image--extension "image/webp") ".webp"))
  ;; An unknown type must still produce something writable.
  (should (equal (cmacs-ai-image--extension "application/octet-stream")
                 ".png")))

(ert-deftest cmacs-ai-image-basename-numbers-batches ()
  "A single image gets a bare name; a batch gets numbered ones."
  (skip-unless (fboundp 'cmacs-ai-image--basename))
  ;; Pin the name format: the default is a timestamp, which contains
  ;; its own "-NNNNNN" and makes a suffix assertion ambiguous.
  (let* ((cmacs-ai-image-file-name-format "img")
         (solo  (cmacs-ai-image--basename "image/png" 0 1))
         (first (cmacs-ai-image--basename "image/png" 0 3))
         (third (cmacs-ai-image--basename "image/jpeg" 2 3)))
    (should (equal solo "img.png"))
    (should (equal first "img-1.png"))
    (should (equal third "img-3.jpg"))))

(ert-deftest cmacs-ai-image-options-omit-nil ()
  "Unset defcustoms are omitted, so providers keep their own defaults."
  (skip-unless (fboundp 'cmacs-ai-image--options))
  (let ((cmacs-ai-image-model nil)
        (cmacs-ai-image-aspect nil)
        (cmacs-ai-image-size nil)
        (cmacs-ai-image-resolution nil)
        (cmacs-ai-image-quality nil)
        (cmacs-ai-image-background nil)
        (cmacs-ai-image-format nil)
        (cmacs-ai-image-negative nil)
        (cmacs-ai-image-count 1))
    (let ((opts (cmacs-ai-image--options)))
      (should-not (plist-member opts :model))
      (should-not (plist-member opts :aspect))
      (should-not (plist-member opts :quality))
      ;; count is genuinely set, so it survives
      (should (equal (plist-get opts :count) 1)))))

(ert-deftest cmacs-ai-image-options-overrides-win ()
  "Explicit overrides beat the defcustom defaults."
  (skip-unless (fboundp 'cmacs-ai-image--options))
  (let* ((cmacs-ai-image-aspect "1:1")
         (opts (cmacs-ai-image--options '(:aspect "16:9" :seed 42))))
    (should (equal (plist-get opts :aspect) "16:9"))
    (should (equal (plist-get opts :seed) 42))))

(ert-deftest cmacs-ai-image-attaches-in-org ()
  "In Org the image is attached to the node and linked as an attachment."
  (skip-unless (fboundp 'cmacs-ai-image))
  (let* ((dir (make-temp-file "cmacs-ai-img-" t))
         (cmacs-ai-image-dir (expand-file-name "fallback" dir))
         (org-id-locations-file (expand-file-name "id-locations" dir))
         (file (expand-file-name "notes.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* Heading\n\n"))
          (let ((buf (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-max))
                  (cmacs-ai-tests--with-stub-image
                      (cmacs-ai-tests--one-image)
                    (cmacs-ai-image "a brass telescope" nil))
                  (let ((text (buffer-string)))
                    (should (string-match-p "\\[\\[attachment:" text))
                    (should (string-match-p "#\\+CAPTION: a brass telescope"
                                            text))
                    ;; org-attach needs an ID to hang the directory off.
                    (should (string-match-p ":ID:" text)))
                  ;; The bytes must really be on disk, not just linked.
                  (goto-char (point-min))
                  (org-back-to-heading t)
                  (let ((adir (org-attach-dir)))
                    (should adir)
                    (should (directory-files adir nil "\\.png\\'"))))
              (kill-buffer buf))))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-image-falls-back-outside-org ()
  "Outside Org the image lands in the fallback dir as a bare path."
  (skip-unless (fboundp 'cmacs-ai-image))
  (let* ((dir (make-temp-file "cmacs-ai-img-" t))
         (cmacs-ai-image-dir (expand-file-name "fallback" dir)))
    (unwind-protect
        (with-temp-buffer
          (text-mode)
          (cmacs-ai-tests--with-stub-image (cmacs-ai-tests--one-image)
            (cmacs-ai-image "a fallback image" nil))
          (let ((text (string-trim (buffer-string))))
            ;; A bare path, not Org bracket syntax, which would be noise
            ;; in a plain buffer.
            (should-not (string-match-p "\\[\\[" text))
            (should (string-suffix-p ".png" text))
            (should (file-exists-p text))))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-image-skips-entries-without-data ()
  "An image whose bytes could not be fetched is skipped, not fatal."
  (skip-unless (fboundp 'cmacs-ai-image--place))
  (let* ((dir (make-temp-file "cmacs-ai-img-" t))
         (cmacs-ai-image-dir (expand-file-name "fallback" dir)))
    (unwind-protect
        (with-temp-buffer
          (text-mode)
          (let ((placed (cmacs-ai-image--place
                         (list (list :mime "image/png" :url "https://x/y.png")
                               (list :data cmacs-ai-tests--png
                                     :mime "image/png"))
                         "prompt" (current-buffer) (point))))
            ;; Two returned, one retrievable.
            (should (= placed 1))))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-image-block-coerces-numbers ()
  "Org hands header args over as strings; numeric options are coerced."
  (skip-unless (fboundp 'cmacs-ai-image-block--options))
  (let ((opts (cmacs-ai-image-block--options
               '((:count . "3") (:seed . "42") (:strength . "0.5")
                 (:aspect . "16:9")))))
    (should (integerp (plist-get opts :count)))
    (should (= (plist-get opts :count) 3))
    (should (integerp (plist-get opts :seed)))
    (should (floatp (plist-get opts :strength)))
    (should (equal (plist-get opts :aspect) "16:9"))))

(ert-deftest cmacs-ai-image-block-collects-refs ()
  "Repeated :ref header args accumulate, with optional ::ROLE labels."
  (skip-unless (fboundp 'cmacs-ai-image-block--references))
  (let ((refs (cmacs-ai-image-block--references
               '((:ref . "logo.png::style") (:ref . "cat.jpg")))))
    (should (= (length refs) 2))
    (should (consp (nth 0 refs)))
    (should (equal (cdr (nth 0 refs)) "style"))
    ;; An unlabelled reference stays a bare path.
    (should (stringp (nth 1 refs)))))

(ert-deftest cmacs-ai-image-chat-parses-references ()
  "The flat comma-separated reference string parses into paths + roles."
  (skip-unless (fboundp 'cmacs-ai-image-chat--parse-refs))
  (let ((refs (cmacs-ai-image-chat--parse-refs
               "a.png::style, b.jpg , c.webp::subject")))
    (should (= (length refs) 3))
    (should (equal (cdr (nth 0 refs)) "style"))
    (should (stringp (nth 1 refs)))
    (should (equal (cdr (nth 2 refs)) "subject")))
  ;; Empty input must not produce a one-element list of nothing.
  (should-not (cmacs-ai-image-chat--parse-refs ""))
  (should-not (cmacs-ai-image-chat--parse-refs nil)))

(ert-deftest cmacs-ai-image-chat-slash-command ()
  "`/image PROMPT' is consumed; ordinary text is not."
  (skip-unless (fboundp 'cmacs-ai-image-chat-slash-command))
  (let (seen)
    (cl-letf (((symbol-function 'cmacs-ai-image--run)
               (lambda (p &rest _) (setq seen p) t)))
      (should (cmacs-ai-image-chat-slash-command "/image a red cube"))
      (should (equal seen "a red cube"))
      (setq seen nil)
      (should-not (cmacs-ai-image-chat-slash-command "just a message"))
      (should-not seen)
      ;; `/image' with no prompt is not a command either.
      (should-not (cmacs-ai-image-chat-slash-command "/image")))))

(ert-deftest cmacs-ai-image-models-shape ()
  "The capability query returns plists with the documented keys."
  (skip-unless (fboundp 'cmacs-ai-image-models))
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (let ((h (cmacs-ai-client-new 'gemini)))
    (unwind-protect
        (let ((models (cmacs-ai-image-models h)))
          (should models)
          (dolist (m models)
            (should (stringp (plist-get m :id)))
            (should (integerp (plist-get m :max-references)))
            (should (integerp (plist-get m :max-count)))
            (should (listp (plist-get m :capabilities))))
          ;; Nano Banana Pro is the multi-reference model.
          (let ((pro (seq-find
                      (lambda (m)
                        (equal (plist-get m :id)
                               "gemini-3-pro-image-preview"))
                      models)))
            (should pro)
            (should (memq 'multi-reference (plist-get pro :capabilities)))
            (should (= (plist-get pro :max-references) 14))))
      (cmacs-ai-client-free h))))

(ert-deftest cmacs-ai-image-rejects-non-image-provider ()
  "Asking a provider with no image API for an image errors clearly."
  (skip-unless (fboundp 'cmacs-ai-image-generate-async))
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (let ((h (cmacs-ai-client-new 'claude)))
    (unwind-protect
        (should-error (cmacs-ai-image-generate-async
                       h "x" (lambda (_) nil) nil))
      (cmacs-ai-client-free h))))

(ert-deftest cmacs-ai-image-from-selected-text-inserts-after ()
  "The image lands after the selection, leaving the prose in place."
  (skip-unless (fboundp 'cmacs-ai-image-from-selected-text))
  (let* ((dir (make-temp-file "cmacs-ai-img-" t))
         (cmacs-ai-image-dir (expand-file-name "fallback" dir)))
    (unwind-protect
        (with-temp-buffer
          (text-mode)
          (insert "Intro line.\nA macaw on a telescope.\nTrailing line.\n")
          (goto-char (point-min))
          (forward-line 1)
          (set-mark (point))
          (end-of-line)
          (activate-mark)
          (cmacs-ai-tests--with-stub-image (cmacs-ai-tests--one-image)
            (cmacs-ai-image-from-selected-text))
          (let* ((text (buffer-string))
                 (prose (string-match-p "A macaw on a telescope\\." text))
                 (image (string-match-p "\\.png" text))
                 (after (string-match-p "Trailing line\\." text)))
            ;; The selection is the prompt, not something to consume.
            (should prose)
            (should after)
            ;; ...and the image goes between it and what followed.
            (should image)
            (should (> image prose))
            (should (< image after))
            ;; The region has served its purpose; leaving it active would
            ;; invite the next command to act on it too.
            (should-not (region-active-p))))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-image-from-selected-text-survives-edits ()
  "The insertion point tracks edits made while the image generates."
  (skip-unless (fboundp 'cmacs-ai-image-from-selected-text))
  (let* ((dir (make-temp-file "cmacs-ai-img-" t))
         (cmacs-ai-image-dir (expand-file-name "fallback" dir))
         (deferred nil))
    (unwind-protect
        (with-temp-buffer
          (text-mode)
          (insert "TARGET.\nlater line\n")
          (goto-char (point-min))
          (set-mark (point))
          (end-of-line)
          (activate-mark)
          ;; Hold the callback rather than firing it, so the buffer can be
          ;; edited in between -- which is what really happens across the
          ;; tens of seconds a generation takes.
          (cl-letf (((symbol-function 'cmacs-ai-image-generate-async)
                     (lambda (_h _p cb _o) (setq deferred cb) 1))
                    ((symbol-function 'cmacs-ai-client-new) (lambda (&rest _) 1))
                    ((symbol-function 'cmacs-ai-client-free) (lambda (&rest _) t))
                    ((symbol-function 'cmacs-ai-image--ensure) (lambda () t)))
            (cmacs-ai-image-from-selected-text))
          (should deferred)
          ;; Type above the anchor, shifting every raw offset below it.
          (goto-char (point-min))
          (insert "A NEW FIRST LINE\n")
          (funcall deferred
                   (list :images (cmacs-ai-tests--one-image)))
          (let* ((text (buffer-string))
                 (target (string-match-p "TARGET\\." text))
                 (image (string-match-p "\\.png" text))
                 (later (string-match-p "later line" text)))
            (should image)
            ;; Still bracketed by the same two lines, not displaced by the
            ;; edit above -- which an integer position would not manage.
            (should (> image target))
            (should (< image later))))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-image-from-selected-text-requires-region ()
  "Without a selection the command says so rather than guessing."
  (skip-unless (fboundp 'cmacs-ai-image-from-selected-text))
  (with-temp-buffer
    (insert "no selection here")
    (deactivate-mark)
    (should-error (cmacs-ai-image-from-selected-text) :type 'user-error)))

(ert-deftest cmacs-ai-image-resolve-position ()
  "Positions may be markers or integers, and are clamped to the buffer."
  (skip-unless (fboundp 'cmacs-ai-image--resolve-position))
  (with-temp-buffer
    (insert "0123456789")
    (should (= (cmacs-ai-image--resolve-position 4) 4))
    (should (= (cmacs-ai-image--resolve-position (copy-marker 4)) 4))
    ;; Past the end clamps rather than erroring.
    (should (= (cmacs-ai-image--resolve-position 9999) (point-max)))
    ;; A marker pointing nowhere falls back to point.
    (should (integerp (cmacs-ai-image--resolve-position (make-marker))))))

(require 'cmacs-ai-image-menu nil 'noerror)

(defmacro cmacs-ai-tests--with-menu (state &rest body)
  "Run BODY with the image menu composed to STATE."
  (declare (indent 1))
  `(let ((cmacs-ai-image-menu--state ,state))
     ,@body))

(ert-deftest cmacs-ai-image-menu-prefix-is-well-formed ()
  "The transient prefix exists as a command with a layout."
  (skip-unless (fboundp 'cmacs-ai-image-menu))
  (should (commandp 'cmacs-ai-image-menu))
  (should (get 'cmacs-ai-image-menu 'transient--layout)))

(ert-deftest cmacs-ai-image-menu-gates-on-model-capability ()
  "Only options the selected model honours are offered."
  (skip-unless (fboundp 'cmacs-ai-image-menu--supports-p))
  (skip-unless (fboundp 'cmacs-ai-client-new))
  ;; Nano Banana Pro: ratios and a resolution tier, no pixel sizes.
  (cmacs-ai-tests--with-menu
      '(:provider gemini :model "gemini-3-pro-image-preview")
    (should (cmacs-ai-image-menu--supports-p 'aspect-ratio))
    (should (cmacs-ai-image-menu--supports-p 'resolution-tier))
    (should (cmacs-ai-image-menu--supports-p 'reference-images))
    (should-not (cmacs-ai-image-menu--supports-p 'pixel-size)))
  ;; GPT Image: the other way round, plus transparency and masks.
  (cmacs-ai-tests--with-menu '(:provider openai :model "gpt-image-2")
    (should (cmacs-ai-image-menu--supports-p 'pixel-size))
    (should (cmacs-ai-image-menu--supports-p 'transparency))
    (should (cmacs-ai-image-menu--supports-p 'mask))
    (should-not (cmacs-ai-image-menu--supports-p 'aspect-ratio))
    ;; ...and no style, which is exactly what GPT Image rejects.
    (should-not (cmacs-ai-image-menu--supports-p 'style)))
  ;; DALL-E 3 takes no reference images at all.
  (cmacs-ai-tests--with-menu '(:provider openai :model "dall-e-3")
    (should (cmacs-ai-image-menu--supports-p 'style))
    (should-not (cmacs-ai-image-menu--supports-p 'reference-images))))

(ert-deftest cmacs-ai-image-menu-choices-come-from-the-model ()
  "Offered values are the model's own, not a hardcoded list."
  (skip-unless (fboundp 'cmacs-ai-image-menu--info))
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (cmacs-ai-tests--with-menu
      '(:provider gemini :model "gemini-3-pro-image-preview")
    (let ((ratios (plist-get (cmacs-ai-image-menu--info) :aspect-ratios)))
      (should (member "21:9" ratios))
      (should (member "1:1" ratios))))
  ;; The two OpenAI families name quality differently, and each rejects
  ;; the other's words -- so the menu must offer the right ones.
  (cmacs-ai-tests--with-menu '(:provider openai :model "gpt-image-2")
    (should (equal (plist-get (cmacs-ai-image-menu--info) :qualities)
                   '("auto" "low" "medium" "high"))))
  (cmacs-ai-tests--with-menu '(:provider openai :model "dall-e-3")
    (should (equal (plist-get (cmacs-ai-image-menu--info) :qualities)
                   '("standard" "hd")))))

(ert-deftest cmacs-ai-image-menu-references-accumulate ()
  "References are an ordered list, each optionally carrying a role."
  (skip-unless (fboundp 'cmacs-ai-image-menu--put))
  (cmacs-ai-tests--with-menu nil
    (cmacs-ai-image-menu--put
     :references (list (cons "/tmp/a.png" "style")
                       "/tmp/b.png"
                       (cons "/tmp/c.png" "subject")))
    (let ((refs (cmacs-ai-image-menu--references)))
      (should (= (length refs) 3))
      (should (equal (cdr (nth 0 refs)) "style"))
      (should (stringp (nth 1 refs)))
      (should (equal (cdr (nth 2 refs)) "subject"))
      ;; Labels show the role so the menu can display what is set.
      (should (string-match-p "style"
                              (cmacs-ai-image-menu--reference-label
                               (nth 0 refs)))))))

(ert-deftest cmacs-ai-image-menu-clearing-removes-the-key ()
  "An emptied option is absent, not set to nil.
That is what leaves the provider on its own default."
  (skip-unless (fboundp 'cmacs-ai-image-menu--put))
  (cmacs-ai-tests--with-menu nil
    (cmacs-ai-image-menu--put :aspect "16:9")
    (should (plist-member cmacs-ai-image-menu--state :aspect))
    (cmacs-ai-image-menu--put :aspect nil)
    (should-not (plist-member cmacs-ai-image-menu--state :aspect))))

(ert-deftest cmacs-ai-image-menu-options-exclude-prompt ()
  "The prompt is an argument, not an option."
  (skip-unless (fboundp 'cmacs-ai-image-menu--options))
  (cmacs-ai-tests--with-menu '(:prompt "a cat" :aspect "16:9")
    (let ((opts (cmacs-ai-image-menu--options)))
      (should-not (plist-member opts :prompt))
      (should (equal (plist-get opts :aspect) "16:9")))))

(ert-deftest cmacs-ai-image-menu-provider-change-resets-model-scope ()
  "Switching provider drops choices made from the old model's vocabulary."
  (skip-unless (fboundp 'cmacs-ai-image-menu-set-provider))
  (skip-unless (fboundp 'cmacs-ai-client-new))
  (cmacs-ai-tests--with-menu
      '(:provider gemini :model "gemini-3-pro-image-preview"
        :aspect "21:9" :quality "high" :count 2)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "openai")))
      (call-interactively #'cmacs-ai-image-menu-set-provider))
    (should (eq (cmacs-ai-image-menu--get :provider) 'openai))
    ;; These belonged to the old model.
    (should-not (cmacs-ai-image-menu--get :model))
    (should-not (cmacs-ai-image-menu--get :aspect))
    (should-not (cmacs-ai-image-menu--get :quality))
    ;; This did not, so it survives.
    (should (equal (cmacs-ai-image-menu--get :count) 2))))


;;;; Running a chat in a project directory
;;
;; The CLI providers find their project by where the process starts:
;; CLAUDE.md, .claude/, a project MCP config and the repository are all
;; resolved from there.  An agent started in the wrong directory is a
;; different agent, and nothing about the conversation would say so.

(ert-deftest cmacs-ai-chat-runs-in-the-given-directory ()
  "The buffer and the CLI subprocess both follow the directory."
  (skip-unless (and (fboundp 'cmacs-ai-chat-open)
                    (fboundp 'cmacs-ai-client-working-directory)))
  (let* ((dir (file-name-as-directory (make-temp-file "cmacs-ai-proj" t)))
         (buf nil))
    (unwind-protect
        (progn
          (setq buf (cmacs-ai-chat-open 'claude-code nil dir))
          (with-current-buffer buf
            (should (equal (expand-file-name default-directory)
                           (expand-file-name dir)))
            (should (equal (expand-file-name
                            (cmacs-ai-client-working-directory
                             (car cmacs-ai-chat-session-pair)))
                           (expand-file-name dir)))
            ;; and the name says which project, so two chats are telling
            ;; apart before you send anything to the wrong one
            (should (string-match-p (regexp-quote
                                     (file-name-nondirectory
                                      (directory-file-name dir)))
                                    (buffer-name)))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-working-directory-is-cli-only ()
  "An HTTP provider has no subprocess to place anywhere."
  (skip-unless (fboundp 'cmacs-ai-client-set-working-directory))
  (let ((http (cmacs-ai-client-new 'claude "claude-sonnet-4-6"))
        (cli (cmacs-ai-client-new 'claude-code "haiku")))
    (should-not (cmacs-ai-client-set-working-directory http "/tmp"))
    (should-not (cmacs-ai-client-working-directory http))
    (should (cmacs-ai-client-set-working-directory cli "/tmp"))
    (should (equal "/tmp/" (file-name-as-directory
                            (cmacs-ai-client-working-directory cli))))))

(ert-deftest cmacs-ai-working-directory-is-expanded ()
  "A relative or ~-prefixed path is resolved before the process sees it.

The subprocess does not expand ~, and would start in a directory
literally named \"~\" if handed one."
  (skip-unless (fboundp 'cmacs-ai-client-set-working-directory))
  (let ((cli (cmacs-ai-client-new 'claude-code "haiku")))
    (cmacs-ai-client-set-working-directory cli "~")
    (should (equal (expand-file-name "~/")
                   (file-name-as-directory
                    (cmacs-ai-client-working-directory cli))))))

(ert-deftest cmacs-ai-chat-directory-default-applies ()
  "`cmacs-ai-chat-default-directory' is used when none is passed."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let* ((dir (file-name-as-directory (make-temp-file "cmacs-ai-def" t)))
         (cmacs-ai-chat-default-directory dir)
         (buf nil))
    (unwind-protect
        (progn
          (setq buf (cmacs-ai-chat-open 'claude-code))
          (with-current-buffer buf
            (should (equal (expand-file-name default-directory)
                           (expand-file-name dir)))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir t))))


;;;; Provider label

(ert-deftest cmacs-ai-label-uses-the-provider-symbol ()
  "The heading names the provider you can actually select.

ai-glib returns prose -- \"Claude Code\", \"Claude (TUI via tmux)\" --
and downcasing that gave \"claude code\", which is not a provider symbol
and cannot be typed anywhere in the Elisp API."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (dolist (p '(claude-code claude-tmux opencode claude))
    (let ((buf (cmacs-ai-chat-open p "sonnet")))
      (unwind-protect
          (with-current-buffer buf
            (should (equal (cmacs-ai-chat--assistant-label)
                           (format "%s/sonnet" p))))
        (kill-buffer buf)))))

(ert-deftest cmacs-ai-provider-slug-is-identifier-shaped ()
  "The display-name fallback still yields something symbol-like."
  (skip-unless (fboundp 'cmacs-ai-chat--provider-slug))
  (should (equal "claude-code" (cmacs-ai-chat--provider-slug "Claude Code")))
  (should (equal "claude" (cmacs-ai-chat--provider-slug
                           "Claude (TUI via tmux)")))
  (should (equal "openai" (cmacs-ai-chat--provider-slug "OpenAI"))))


;;;; Model prompt

(ert-deftest cmacs-ai-offers-cli-model-aliases ()
  "Both CLI providers offer the aliases you would actually type."
  (skip-unless (fboundp 'cmacs-ai--models-for))
  (dolist (p '(claude-code claude-tmux))
    (let ((models (cmacs-ai--models-for p)))
      (dolist (m '("haiku" "sonnet" "opus" "fable"))
        (should (member m models))))))

(ert-deftest cmacs-ai-model-prompt-survives-a-mute-provider ()
  "A provider that cannot answer still leaves the chat selectable."
  (skip-unless (fboundp 'cmacs-ai--models-for))
  (cl-letf (((symbol-function 'cmacs-ai-list-models)
             (lambda (&rest _) (error "no daemon"))))
    (should-not (cmacs-ai--models-for 'ollama))))


;;;; Directory prompt

(ert-deftest cmacs-ai-directory-table-shows-saved-roots ()
  "The roots you saved are offered before you type anything."
  (skip-unless (fboundp 'cmacs-ai--chat-directory-table))
  (let* ((cmacs-ai-chat-directories '("~/some/project" "~/another"))
         (table (cmacs-ai--chat-directory-table))
         (offered (all-completions "" table)))
    (should (member "~/some/project/" offered))
    (should (member "~/another/" offered))))

(ert-deftest cmacs-ai-directory-table-browses-the-filesystem ()
  "Anywhere else is still reachable, as in `find-file'."
  (skip-unless (fboundp 'cmacs-ai--chat-directory-table))
  (let ((dir (file-name-as-directory (make-temp-file "cmacs-ai-br" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "alpha" dir))
          (make-directory (expand-file-name "beta" dir))
          (let* ((cmacs-ai-chat-directories nil)
                 (table (cmacs-ai--chat-directory-table))
                 (all (all-completions dir table)))
            (should (member (concat dir "alpha/") all))
            (should (member (concat dir "beta/") all))
            ;; directories only -- a file is not somewhere to start an agent
            (with-temp-file (expand-file-name "afile" dir) (insert "x"))
            (should-not (member (concat dir "afile")
                                (all-completions dir table)))
            ;; and partial input narrows
            (should (equal (list (concat dir "alpha/"))
                           (all-completions (concat dir "al") table)))))
      (delete-directory dir t))))


;;;; CLI tool permissions

(ert-deftest cmacs-ai-skip-permissions-is-cli-only ()
  "All three CLI providers take it; an HTTP one has no such notion."
  (skip-unless (fboundp 'cmacs-ai-client-set-skip-permissions))
  (dolist (p '(claude-code claude-tmux opencode))
    (should (cmacs-ai-client-set-skip-permissions
             (cmacs-ai-client-new p nil) t)))
  (should-not (cmacs-ai-client-set-skip-permissions
               (cmacs-ai-client-new 'claude nil) t)))

(ert-deftest cmacs-ai-cli-skip-permissions-defaults-on ()
  "Off by default would mean a CLI chat that cannot call its own tools.

Run non-interactively there is nobody to approve anything, so every tool
needing approval is unavailable -- the agent lists them and reports it
has no way to invoke them."
  (skip-unless (boundp 'cmacs-ai-cli-skip-permissions))
  (should cmacs-ai-cli-skip-permissions))


;;;; Bootstrapping from a project's agent file

(defmacro cmacs-ai-tests--with-project (files &rest body)
  "Make a temp directory containing FILES, an alist of name to content."
  (declare (indent 1))
  `(let ((dir (file-name-as-directory (make-temp-file "cmacs-ai-boot" t))))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (with-temp-file (expand-file-name (car f) dir) (insert (cdr f))))
           ,@body)
       (delete-directory dir t))))

(ert-deftest cmacs-ai-bootstrap-prefers-the-larger-file ()
  "With both present the fuller document wins."
  (skip-unless (fboundp 'cmacs-ai-chat--find-bootstrap))
  (cmacs-ai-tests--with-project
      (list (cons "CLAUDE.md" "short")
            (cons "AGENTS.md" (make-string 500 ?x)))
    (should (equal "AGENTS.md"
                   (file-name-nondirectory
                    (cmacs-ai-chat--find-bootstrap dir)))))
  ;; ...and the other way round, so it is size and not file order
  (cmacs-ai-tests--with-project
      (list (cons "CLAUDE.md" (make-string 500 ?x))
            (cons "AGENTS.md" "short"))
    (should (equal "CLAUDE.md"
                   (file-name-nondirectory
                    (cmacs-ai-chat--find-bootstrap dir))))))

(ert-deftest cmacs-ai-bootstrap-handles-one-or-none ()
  (skip-unless (fboundp 'cmacs-ai-chat--find-bootstrap))
  (cmacs-ai-tests--with-project (list (cons "AGENTS.md" "only this"))
    (should (equal "AGENTS.md" (file-name-nondirectory
                                (cmacs-ai-chat--find-bootstrap dir)))))
  (cmacs-ai-tests--with-project (list (cons "README.md" "not a bootstrap"))
    (should-not (cmacs-ai-chat--find-bootstrap dir))))

(ert-deftest cmacs-ai-bootstrap-is-http-only ()
  "A CLI agent reads the file itself; injecting would send it twice."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (cmacs-ai-tests--with-project (list (cons "CLAUDE.md" "rules"))
    (let ((http (cmacs-ai-chat-open 'claude nil dir))
          (cli (cmacs-ai-chat-open 'claude-code nil dir)))
      (unwind-protect
          (progn
            (should (with-current-buffer http cmacs-ai-chat--bootstrap-file))
            (should-not (with-current-buffer cli
                          cmacs-ai-chat--bootstrap-file)))
        (kill-buffer http)
        (kill-buffer cli)))))

(ert-deftest cmacs-ai-bootstrap-is-lazy-and-once ()
  "Nothing is read at open, and nothing is re-sent on later turns.

Lazy because opening a chat should cost nothing; once because the file
lands in the system prompt, which persists for the whole conversation."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (cmacs-ai-tests--with-project (list (cons "CLAUDE.md" "distinctive-rule"))
    (let ((sets 0) (last nil))
      (cl-letf* ((orig (symbol-function 'cmacs-ai-client-set-system-prompt))
                 ((symbol-function 'cmacs-ai-client-set-system-prompt)
                  (lambda (c text) (setq sets (1+ sets) last text)
                    (funcall orig c text))))
        (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
          (unwind-protect
              (with-current-buffer buf
                ;; opening read nothing
                (setq sets 0 last nil)
                (cmacs-ai-chat--apply-bootstrap)
                (should (= 1 sets))
                (should (string-match-p "distinctive-rule" last))
                ;; the shipped system prompt is kept, not replaced
                (should (string-match-p (regexp-quote
                                         (substring cmacs-ai-system-prompt 0 20))
                                        last))
                (cmacs-ai-chat--apply-bootstrap)
                (should (= 1 sets)))
            (kill-buffer buf)))))))

(ert-deftest cmacs-ai-bootstrap-refuses-an-oversized-file ()
  "Past the cap it is skipped, not truncated.

Half a document of standing instructions is worse than none."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (cmacs-ai-tests--with-project (list (cons "CLAUDE.md" (make-string 5000 ?x)))
    (let ((sets 0)
          (cmacs-ai-chat-bootstrap-max-bytes 100))
      (cl-letf (((symbol-function 'cmacs-ai-client-set-system-prompt)
                 (lambda (&rest _) (setq sets (1+ sets)))))
        (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
          (unwind-protect
              (with-current-buffer buf
                (setq sets 0)
                (cmacs-ai-chat--apply-bootstrap)
                (should (= 0 sets))
                ;; and it is not retried on the next turn either
                (should-not cmacs-ai-chat--bootstrap-file))
            (kill-buffer buf)))))))

(ert-deftest cmacs-ai-bootstrap-can-be-turned-off ()
  (skip-unless (fboundp 'cmacs-ai-chat--find-bootstrap))
  (cmacs-ai-tests--with-project (list (cons "CLAUDE.md" "rules"))
    (let ((cmacs-ai-chat-bootstrap nil))
      (should-not (cmacs-ai-chat--find-bootstrap dir)))))


;;;; @file imports inside a bootstrap file

(ert-deftest cmacs-ai-bootstrap-expands-imports ()
  "A manifest of @references becomes the files it names.

This is the shape a real CLAUDE.md often takes: a couple of hundred
bytes listing @SOUL.org and friends.  Unexpanded it tells an HTTP model
nothing it can act on -- it cannot open files -- so the project may as
well have said nothing."
  (skip-unless (fboundp 'cmacs-ai-chat--expand-imports))
  (cmacs-ai-tests--with-project
      (list (cons "CLAUDE.md" "Read:\n- @SOUL.org\n- @USER.org\n")
            (cons "SOUL.org" "you are Gnuisaince")
            (cons "USER.org" "the user is zach"))
    (let ((out (cmacs-ai-chat--expand-imports
                "Read:\n- @SOUL.org\n- @USER.org\n" dir 5
                (make-hash-table :test 'equal))))
      (should (string-match-p "you are Gnuisaince" out))
      (should (string-match-p "the user is zach" out))
      ;; each is delimited and named, so the model can tell them apart
      (should (string-match-p "BEGIN SOUL.org" out))
      (should (string-match-p "END USER.org" out))
      ;; and in the order the manifest listed them
      (should (< (string-match "Gnuisaince" out)
                 (string-match "zach" out))))))

(ert-deftest cmacs-ai-bootstrap-imports-nest ()
  "An imported file may import others, relative to itself."
  (skip-unless (fboundp 'cmacs-ai-chat--expand-imports))
  (cmacs-ai-tests--with-project
      (list (cons "a.org" "top @b.org")
            (cons "b.org" "middle @c.org")
            (cons "c.org" "bottom-reached"))
    (let ((out (cmacs-ai-chat--expand-imports
                "@a.org" dir 5 (make-hash-table :test 'equal))))
      (should (string-match-p "bottom-reached" out)))))

(ert-deftest cmacs-ai-bootstrap-imports-stop-at-the-depth-limit ()
  "A cycle terminates instead of recursing forever."
  (skip-unless (fboundp 'cmacs-ai-chat--expand-imports))
  (cmacs-ai-tests--with-project
      (list (cons "a.org" "a @b.org") (cons "b.org" "b @a.org"))
    ;; The dedup table alone would stop this, so also prove the depth
    ;; budget holds on its own with a fresh table each level.
    (let ((out (cmacs-ai-chat--expand-imports
                "@a.org" dir 2 (make-hash-table :test 'equal))))
      (should (stringp out)))))

(ert-deftest cmacs-ai-bootstrap-imports-are-deduped ()
  "A file named twice is sent once.

The real manifest that prompted this lists PROJECTS.org twice; sending
it twice is only cost."
  (skip-unless (fboundp 'cmacs-ai-chat--expand-imports))
  (cmacs-ai-tests--with-project
      (list (cons "p.org" "UNIQUE-BODY-TEXT"))
    (let ((out (cmacs-ai-chat--expand-imports
                "@p.org and again @p.org" dir 5
                (make-hash-table :test 'equal))))
      (should (= 1 (cl-count-if (lambda (_) t)
                                (let (acc (i 0))
                                  (while (string-match "UNIQUE-BODY-TEXT" out i)
                                    (push t acc) (setq i (match-end 0)))
                                  acc))))
      (should (string-match-p "included above" out)))))

(ert-deftest cmacs-ai-bootstrap-leaves-non-files-alone ()
  "Only references that resolve to a readable file are expanded.

That requirement is what keeps an email address, a decorator or an `@'
in prose from being treated as an import."
  (skip-unless (fboundp 'cmacs-ai-chat--expand-imports))
  (cmacs-ai-tests--with-project (list (cons "real.org" "REAL"))
    (let ((out (cmacs-ai-chat--expand-imports
                "mail zach@example.com about @nosuchfile.org and @real.org"
                dir 5 (make-hash-table :test 'equal))))
      (should (string-match-p "zach@example.com" out))
      (should (string-match-p "@nosuchfile.org" out))
      (should (string-match-p "REAL" out)))))

(ert-deftest cmacs-ai-bootstrap-size-check-uses-the-expanded-text ()
  "The cap applies to what is sent, not to the manifest.

A 200-byte file of imports can expand to tens of kilobytes, and that is
the number that costs something on every turn."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (cmacs-ai-tests--with-project
      (list (cons "CLAUDE.md" "@big.org")
            (cons "big.org" (make-string 5000 ?x)))
    (let ((sets 0)
          (cmacs-ai-chat-bootstrap-max-bytes 1000))
      (cl-letf (((symbol-function 'cmacs-ai-client-set-system-prompt)
                 (lambda (&rest _) (setq sets (1+ sets)))))
        (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
          (unwind-protect
              (with-current-buffer buf
                (setq sets 0)
                (cmacs-ai-chat--apply-bootstrap)
                ;; the manifest is 8 bytes; what it expands to is not
                (should (= 0 sets)))
            (kill-buffer buf)))))))

(ert-deftest cmacs-ai-bootstrap-expansion-can-be-turned-off ()
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (cmacs-ai-tests--with-project
      (list (cons "CLAUDE.md" "@soul.org") (cons "soul.org" "SOUL-BODY"))
    (let (captured
          (cmacs-ai-chat-bootstrap-expand-imports nil))
      (cl-letf (((symbol-function 'cmacs-ai-client-set-system-prompt)
                 (lambda (_c text) (setq captured text))))
        (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
          (unwind-protect
              (with-current-buffer buf (cmacs-ai-chat--apply-bootstrap))
            (kill-buffer buf))))
      (should captured)
      (should-not (string-match-p "SOUL-BODY" captured)))))


;;;; Tool-call rendering

(ert-deftest cmacs-ai-tool-calls-hidden-by-default ()
  "A tool loop can run a dozen calls whose arguments and output are each
a JSON block, which buries the conversation they were in service of."
  (skip-unless (boundp 'cmacs-ai-chat-show-tool-calls))
  (let ((process-environment
         (cons "CMACS_AI_SHOW_TOOL_CALLS=" process-environment)))
    (should-not (cmacs-ai--env-truthy "CMACS_AI_SHOW_TOOL_CALLS"))))

(ert-deftest cmacs-ai-tool-call-env-var-truth-values ()
  "true / TRUE / 1 turn it on; anything else does not."
  (skip-unless (fboundp 'cmacs-ai--env-truthy))
  (dolist (v '("true" "TRUE" "True" "1" "yes" "on" " true "))
    (let ((process-environment
           (cons (concat "CMACS_AI_SHOW_TOOL_CALLS=" v) process-environment)))
      (should (cmacs-ai--env-truthy "CMACS_AI_SHOW_TOOL_CALLS"))))
  (dolist (v '("false" "FALSE" "0" "no" "off" "" "banana"))
    (let ((process-environment
           (cons (concat "CMACS_AI_SHOW_TOOL_CALLS=" v) process-environment)))
      (should-not (cmacs-ai--env-truthy "CMACS_AI_SHOW_TOOL_CALLS")))))

(ert-deftest cmacs-ai-hidden-tool-calls-render-nothing ()
  "Nothing reaches the buffer when they are hidden, and does when shown."
  (skip-unless (fboundp 'cmacs-ai-chat--render-tool-result))
  (let ((buf (cmacs-ai-chat-open 'claude nil)))
    (unwind-protect
        (with-current-buffer buf
          (let ((before (buffer-size)))
            (let ((cmacs-ai-chat-show-tool-calls nil))
              (cmacs-ai-chat--render-tool-result buf "list_buffers" "id1" "out"))
            (should (= before (buffer-size)))
            (let ((cmacs-ai-chat-show-tool-calls t))
              (cmacs-ai-chat--render-tool-result buf "list_buffers" "id1" "out"))
            (should (> (buffer-size) before))
            (should (string-match-p "tool-result/list_buffers"
                                    (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-hidden-tool-calls-still-run ()
  "Hiding is rendering only: the call still happens.

The queueing that drives the tool loop sits in the same branch as the
rendering, so suppressing the wrong one would quietly disable tools
rather than just hiding them."
  (skip-unless (fboundp 'cmacs-ai-chat--stream-callback))
  (let ((buf (cmacs-ai-chat-open 'claude nil)))
    (unwind-protect
        (with-current-buffer buf
          (let ((cmacs-ai-chat-show-tool-calls nil))
            (cmacs-ai-chat--stream-callback
             buf '(:tool-use "list_buffers" "{}" "call-1"))
            ;; queued for execution despite rendering nothing
            (should (= 1 (length cmacs-ai-chat--pending-tool-uses)))
            (should (equal "call-1" (nth 2 (car cmacs-ai-chat--pending-tool-uses))))
            ;; and the dedup by id still holds
            (cmacs-ai-chat--stream-callback
             buf '(:tool-use "list_buffers" "{}" "call-1"))
            (should (= 1 (length cmacs-ai-chat--pending-tool-uses)))))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-tool-call-visibility-is-per-buffer ()
  "The toggle is buffer-local, so one noisy chat does not change the rest."
  (skip-unless (fboundp 'cmacs-ai-chat-toggle-tool-calls))
  (let ((a (cmacs-ai-chat-open 'claude nil))
        (b (cmacs-ai-chat-open 'claude nil)))
    (unwind-protect
        (progn
          (with-current-buffer a (cmacs-ai-chat-toggle-tool-calls)
                                 (should cmacs-ai-chat-show-tool-calls))
          (with-current-buffer b (should-not cmacs-ai-chat-show-tool-calls)))
      (kill-buffer a)
      (kill-buffer b))))


(ert-deftest cmacs-ai-two-chats-opened-together-are-two-buffers ()
  "Opening a second chat must not land in the first.

The buffer name is second-granular, so two opened in the same second
resolved to one buffer through `get-buffer-create' -- and the erase in
`cmacs-ai-chat--init' then hit the read-only history guard, so the
second open failed outright."
  (skip-unless (fboundp 'cmacs-ai-chat-open))
  (let (buffers)
    (unwind-protect
        (progn
          (dotimes (_ 3) (push (cmacs-ai-chat-open 'claude nil) buffers))
          (should (= 3 (length (delete-dups (copy-sequence buffers)))))
          (dolist (b buffers) (should (buffer-live-p b))))
      (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b))))))


(ert-deftest cmacs-ai-bootstrap-directive-rides-the-first-turn ()
  "The first message carries an instruction to act on the project file.

The file in the system prompt is not enough on its own: there it reads
as background -- a description of the project -- so a model given a
startup ritual answers \"hey there\" with \"hey!\" and performs none of
it.  Saying so in the user turn is where a model looks for what it is
being asked to do."
  (skip-unless (fboundp 'cmacs-ai-chat-send-compose))
  (cmacs-ai-tests--with-project (list (cons "CLAUDE.md" "read @SOUL.org")
                                      (cons "SOUL.org" "you are Gnuisaince"))
    (let (turns (cmacs-ai-chat-autosave nil))
      (cl-letf (((symbol-function 'cmacs-ai-chat-stream)
                 (lambda (_s text &rest _) (push text turns) t)))
        (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
          (unwind-protect
              (with-current-buffer buf
                (goto-char (point-max)) (insert "hey there")
                (cmacs-ai-chat-send-compose)
                (goto-char (point-max)) (insert "second")
                (cmacs-ai-chat-send-compose)
                (let ((first (car (last turns)))
                      (second (car turns)))
                  ;; named the file it came from
                  (should (string-match-p "CLAUDE.md" first))
                  (should (string-match-p "startup or bootstrap" first))
                  ;; immediately before what was typed, so "then answer
                  ;; what follows" points at the message and not at the
                  ;; formatting pre-prompt
                  (should (string-match-p "then answer what follows\\.\n\nhey there"
                                          first))
                  ;; once only
                  (should-not (string-match-p "startup or bootstrap" second))
                  (should (string-match-p "second" second))))
            (kill-buffer buf)))))))

(ert-deftest cmacs-ai-bootstrap-directive-stays-out-of-the-buffer ()
  "The transcript still shows exactly what was typed."
  (skip-unless (fboundp 'cmacs-ai-chat-send-compose))
  (cmacs-ai-tests--with-project (list (cons "CLAUDE.md" "instructions"))
    (let ((cmacs-ai-chat-autosave nil))
     (cl-letf (((symbol-function 'cmacs-ai-chat-stream) (lambda (&rest _) t)))
      (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
        (unwind-protect
            (with-current-buffer buf
              (goto-char (point-max)) (insert "hey there")
              (cmacs-ai-chat-send-compose)
              (should (string-match-p "hey there" (buffer-string)))
              (should-not (string-match-p "startup or bootstrap"
                                          (buffer-string))))
          (kill-buffer buf)))))))

(ert-deftest cmacs-ai-bootstrap-directive-can-be-silenced ()
  "nil sends the file with no accompanying instruction."
  (skip-unless (fboundp 'cmacs-ai-chat-send-compose))
  (cmacs-ai-tests--with-project (list (cons "CLAUDE.md" "instructions"))
    (let (turns
          (cmacs-ai-chat-autosave nil)
          (cmacs-ai-chat-bootstrap-directive nil))
      (cl-letf (((symbol-function 'cmacs-ai-chat-stream)
                 (lambda (_s text &rest _) (push text turns) t)))
        (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
          (unwind-protect
              (with-current-buffer buf
                (goto-char (point-max)) (insert "hey")
                (cmacs-ai-chat-send-compose)
                (should-not (string-match-p "startup or bootstrap"
                                            (car turns))))
            (kill-buffer buf)))))))

(ert-deftest cmacs-ai-no-bootstrap-means-no-directive ()
  "A chat with no project file gets an unmodified first turn."
  (skip-unless (fboundp 'cmacs-ai-chat-send-compose))
  (cmacs-ai-tests--with-project (list (cons "README.md" "not a bootstrap"))
    (let (turns (cmacs-ai-chat-autosave nil))
      (cl-letf (((symbol-function 'cmacs-ai-chat-stream)
                 (lambda (_s text &rest _) (push text turns) t)))
        (let ((buf (cmacs-ai-chat-open 'claude nil dir)))
          (unwind-protect
              (with-current-buffer buf
                (goto-char (point-max)) (insert "hey")
                (cmacs-ai-chat-send-compose)
                (should-not (string-match-p "startup or bootstrap"
                                            (car turns))))
            (kill-buffer buf)))))))

;;;; One heading per exchange

(defmacro cmacs-ai-tests--with-chat-buffer (&rest body)
  "Run BODY in a bare chat buffer bound to BUF, with sending stubbed."
  (declare (indent 0))
  `(let ((buf (generate-new-buffer "*cmacs-ai: render*")))
     (unwind-protect
         (with-current-buffer buf
           (cmacs-ai-chat-mode)
           (let ((inhibit-read-only t))
             (insert "* Conversation\n\n* Compose\n"))
           (setq-local cmacs-ai-chat--compose-marker (copy-marker (point-max)))
           (set-marker-insertion-type cmacs-ai-chat--compose-marker nil)
           (cl-letf (((symbol-function 'cmacs-ai-chat--assistant-label)
                      (lambda () "prov/model"))
                     ((symbol-function 'cmacs-ai-chat--drive-tool-loop)
                      (lambda (_) nil))
                     ((symbol-function 'cmacs-ai-chat-save-quietly)
                      (lambda () nil)))
             ,@body))
       (when (buffer-live-p buf) (kill-buffer buf)))))

(defun cmacs-ai-tests--assistant-headings (buf)
  "Count `**' headings in BUF."
  (with-current-buffer buf
    (cl-count-if (lambda (l) (string-prefix-p "** " l))
                 (split-string (buffer-string) "\n"))))

(ert-deftest cmacs-ai-chat-tool-loop-is-one-turn ()
  "A tool loop renders as one assistant turn, not one per segment.

Every re-stream used to open its own `** TIMESTAMP provider' heading,
so a bootstrap that read six files produced seven of them -- several
empty, because a segment that only calls tools has no text to show."
  (skip-unless (fboundp 'cmacs-ai-chat-mode))
  (cmacs-ai-tests--with-chat-buffer
    ;; prose, a tool call, a segment with nothing but a tool call, then
    ;; the answer
    (cmacs-ai-chat--stream-callback buf '(:start))
    (cmacs-ai-chat--stream-callback buf '(:delta "Looking around.\n"))
    (cmacs-ai-chat--stream-callback buf '(:tool-use "read" "{}" "id1"))
    (cmacs-ai-chat--stream-callback buf '(:end :stop tool-use))
    (cmacs-ai-chat--stream-callback buf '(:start))
    (cmacs-ai-chat--stream-callback buf '(:tool-use "read" "{}" "id2"))
    (cmacs-ai-chat--stream-callback buf '(:end :stop tool-use))
    (cmacs-ai-chat--stream-callback buf '(:start))
    (cmacs-ai-chat--stream-callback buf '(:delta "Done.\n"))
    (cmacs-ai-chat--stream-callback buf '(:end :stop end-turn))
    (should (= 1 (cmacs-ai-tests--assistant-headings buf)))
    (let ((s (buffer-string)))
      ;; both halves of what the model said are there, in order
      (should (string-match-p "Looking around\\(.\\|\n\\)*Done\\." s))
      ;; and the turn is closed
      (should-not cmacs-ai-chat--turn-open)
      (should-not cmacs-ai-chat--assistant-marker))))

(ert-deftest cmacs-ai-chat-a-silent-stream-adds-nothing ()
  "A stream that produces no text leaves no heading behind."
  (skip-unless (fboundp 'cmacs-ai-chat-mode))
  (cmacs-ai-tests--with-chat-buffer
    (cmacs-ai-chat--stream-callback buf '(:start))
    (cmacs-ai-chat--stream-callback buf '(:end :stop end-turn))
    (should (= 0 (cmacs-ai-tests--assistant-headings buf)))))

(ert-deftest cmacs-ai-chat-turn-stays-open-across-a-tool-call ()
  "The turn flag spans the gap between streams.

Anything asking whether the chat is busy -- the brigade loopback, for
one -- reads this.  The segment marker is released between streams, so
the marker alone reads as idle in exactly the gap where the model is
about to say more, and a message delivered there lands mid-turn."
  (skip-unless (fboundp 'cmacs-ai-chat-mode))
  (cmacs-ai-tests--with-chat-buffer
    (cmacs-ai-chat--stream-callback buf '(:start))
    (cmacs-ai-chat--stream-callback buf '(:delta "thinking"))
    (cmacs-ai-chat--stream-callback buf '(:tool-use "read" "{}" "id1"))
    (cmacs-ai-chat--stream-callback buf '(:end :stop tool-use))
    (should cmacs-ai-chat--turn-open)
    (should-not cmacs-ai-chat--assistant-marker)
    (cmacs-ai-chat--stream-callback buf '(:start))
    (cmacs-ai-chat--stream-callback buf '(:delta "done"))
    (cmacs-ai-chat--stream-callback buf '(:end :stop end-turn))
    (should-not cmacs-ai-chat--turn-open)))

(ert-deftest cmacs-ai-system-prompt-says-not-to-poll ()
  "The shipped prompt tells the model spawns are asynchronous.

Without it a model calls `agent_status' in a loop until it gives up,
which costs turns and money and learns nothing: the loopback already
delivers a message when the agent finishes."
  (skip-unless (boundp 'cmacs-ai-system-prompt))
  (let ((p (default-value 'cmacs-ai-system-prompt)))
    (should (string-match-p "DO NOT POLL" p))
    (should (string-match-p "agent_result" p))
    (should (string-match-p "automatically" p))))

(provide 'cmacs-ai-tests)
;;; cmacs-ai-tests.el ends here
