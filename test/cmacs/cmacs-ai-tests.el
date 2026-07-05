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

(provide 'cmacs-ai-tests)
;;; cmacs-ai-tests.el ends here
