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
