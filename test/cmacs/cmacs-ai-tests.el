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
  (let ((buf (cmacs-ai-chat-open 'claude)))
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
      (kill-buffer buf))))

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

(provide 'cmacs-ai-tests)
;;; cmacs-ai-tests.el ends here
