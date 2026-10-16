;;; cmacs-gowl-bar-assistant.el --- cmacs half of gowl's ai-assistant widget  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `ai-assistant' bar widget (modules/bar/bar-plugins-assistant.c,
;; docs/bar-widgets/ai-assistant.org) is a chat panel, a local-ollama
;; model manager and a machine view.  Its chat goes through the shared
;; bar AI contract (`cmacs-gowl-bar-ai-run', cmacs-gowl-bar-ai.el); this
;; file is the rest of the cmacs side:
;;
;;   `cmacs-gowl-bar-assistant-push' tells the widget it is running
;;   inside cmacs: `ai-backend' = cmacs, the cmacs-ai provider list, the
;;   default provider and model, and -- a little later, from an idle
;;   timer -- per-provider model lists as `models.<provider>' comma
;;   lists.  Called once at --gowl startup, and again whenever the
;;   provider configuration changes.
;;
;;   `cmacs-gowl-bar-assistant-open-in-chat' is what the panel's "In
;;   cmacs" button runs through `emacsctl eval': it opens a cmacs-ai chat
;;   buffer with the bar's conversation in the compose area, ready to be
;;   continued with the full chat (tools, history, org).
;;
;; Both are reached from the compositor's thread under --gowl (emacsctl
;; eval runs on Emacs's thread, which IS the compositor's), so both
;; return at once and put anything slower on a timer; neither prompts,
;; and neither signals for an ordinary failure.
;;
;; Model lists, and why only some providers get one.  cmacs-ai can list
;; models only SYNCHRONOUSLY (`cmacs-ai-list-models' iterates a private
;; main context until the provider answers, up to thirty seconds).  For
;; the CLI providers that answer is a static table and returns at once;
;; for an HTTP provider it is a network round trip, and an idle timer
;; does not make a blocking call non-blocking -- it only picks when the
;; desktop freezes.  So `cmacs-gowl-bar-assistant-model-list-providers'
;; defaults to the CLI providers.  ollama is deliberately absent: the
;; widget asks ollama for its installed models itself, off the
;; compositor thread.  Every other provider's model chooser falls back
;; to free text, which always works.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-gowl-bar-ai)

(declare-function cmacs-ai-list-models "cmacs-ai-stream.c" (&optional provider))
(declare-function cmacs-ai-chat-open "cmacs-ai-chat"
                  (&optional provider model directory))

(defcustom cmacs-gowl-bar-assistant-widget "ai-assistant"
  "The bar widget the assistant settings are pushed to.
`ai-assistant' unless the widget was added under another id."
  :type 'string
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-assistant-model-list-providers
  '(claude-code claude-tmux opencode grok-build antigravity cursor codex-cli)
  "Providers whose model lists are pushed to the widget.

Listing is synchronous in cmacs-ai, so only providers whose list is a
static table belong here: the CLI providers.  Adding an HTTP provider
works, but costs a network round trip on Emacs's thread -- under
`--gowl', the desktop's -- each time the lists are pushed.  Providers
not offered by this cmacs-ai build are skipped."
  :type '(repeat symbol)
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-assistant-model-list-delay 3
  "Idle seconds before the model lists are pushed.
Startup is busy enough without them; the chooser works with free text
until they arrive."
  :type 'number
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-assistant-seed-header
  "Continuing a conversation from the bar assistant:\n\n"
  "Text put before the bar's conversation in the new chat's compose area."
  :type 'string
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-assistant-send-on-open nil
  "Non-nil sends the bar's conversation as soon as the chat opens.
nil (the default) leaves it in the compose area, so the next question
can be added before anything is sent."
  :type 'boolean
  :group 'cmacs-gowl-bar)

(defvar cmacs-gowl-bar-assistant-list-models-function #'cmacs-ai-list-models
  "Function of one provider symbol returning its model names.
Tests rebind it; everything else leaves it alone.")

(defvar cmacs-gowl-bar-assistant-open-chat-function #'cmacs-ai-chat-open
  "Function of PROVIDER and MODEL that opens and returns a chat buffer.
Tests rebind it; everything else leaves it alone.")

(defvar cmacs-gowl-bar-assistant--model-timer nil
  "The pending idle timer that pushes model lists, or nil.")

;;;; Pushing what cmacs offers --------------------------------------

(defun cmacs-gowl-bar-assistant--clean-models (models)
  "MODELS as strings fit for a comma list: no commas, no blanks."
  (cl-loop for m in models
           for s = (if (symbolp m) (symbol-name m) m)
           when (and (stringp s)
                     (not (string-empty-p s))
                     (not (string-match-p "[,\n]" s)))
           collect s))

(defun cmacs-gowl-bar-assistant--push-model-lists ()
  "Push `models.<provider>' for every provider that can be listed cheaply.
A provider that fails to list is skipped; nothing here signals."
  (setq cmacs-gowl-bar-assistant--model-timer nil)
  (let ((offered (ignore-errors (cmacs-gowl-bar-ai-provider-names)))
        out)
    (dolist (p cmacs-gowl-bar-assistant-model-list-providers)
      (let ((name (if (symbolp p) (symbol-name p) (format "%s" p))))
        (when (member name offered)
          (let ((models (condition-case nil
                            (cmacs-gowl-bar-assistant--clean-models
                             (funcall cmacs-gowl-bar-assistant-list-models-function
                                      (intern name)))
                          (error nil))))
            (when models
              (push (cons (concat "models." name)
                          (mapconcat #'identity models ","))
                    out))))))
    (when out
      (cmacs-gowl-bar-push cmacs-gowl-bar-assistant-widget (nreverse out)))
    nil))

;;;###autoload
(defun cmacs-gowl-bar-assistant-push ()
  "Tell gowl's ai-assistant widget it is running inside cmacs.

Pushes `ai-backend' = cmacs, the default model, and (through
`cmacs-gowl-bar-ai-push-providers') the provider list and default
provider; then schedules the per-provider model lists on an idle timer
\(see `cmacs-gowl-bar-assistant-model-list-providers').  Returns nil at
once and never signals."
  (interactive)
  (let ((model (ignore-errors (cmacs-gowl-bar-ai--model nil nil))))
    (cmacs-gowl-bar-push cmacs-gowl-bar-assistant-widget
                         (list (cons "ai-backend" "cmacs")
                               (cons "ai-default-model"
                                     (if (stringp model) model "")))))
  (condition-case err
      (cmacs-gowl-bar-ai-push-providers cmacs-gowl-bar-assistant-widget)
    (error
     (message "cmacs-gowl-bar-assistant: no provider list: %s"
              (error-message-string err))))
  (when (timerp cmacs-gowl-bar-assistant--model-timer)
    (cancel-timer cmacs-gowl-bar-assistant--model-timer))
  (setq cmacs-gowl-bar-assistant--model-timer
        (and cmacs-gowl-bar-assistant-model-list-providers
             (or (fboundp 'cmacs-ai-list-models)
                 (not (eq cmacs-gowl-bar-assistant-list-models-function
                          #'cmacs-ai-list-models)))
             (run-with-idle-timer cmacs-gowl-bar-assistant-model-list-delay
                                  nil
                                  #'cmacs-gowl-bar-assistant--push-model-lists)))
  nil)

;;;; Continuing in a chat buffer ------------------------------------

(defun cmacs-gowl-bar-assistant--provider (name)
  "The provider symbol for NAME from the bar, or nil for the default.
Only a provider this cmacs-ai offers is taken: anything else from the
other side of `emacsctl eval' falls back to the default."
  (when (and (stringp name) (not (string-empty-p name))
             (member name (ignore-errors (cmacs-gowl-bar-ai-provider-names))))
    (intern name)))

(defun cmacs-gowl-bar-assistant--open (provider model transcript)
  "Open the chat for `cmacs-gowl-bar-assistant-open-in-chat'.
PROVIDER, MODEL and TRANSCRIPT are as given to it.  Runs from a timer;
reports failure with a message rather than an error."
  (condition-case err
      (progn
        (require 'cmacs-ai-chat nil t)
        (let* ((prov (cmacs-gowl-bar-assistant--provider provider))
               (mdl (and (stringp model) (not (string-empty-p model)) model))
               (buf (funcall cmacs-gowl-bar-assistant-open-chat-function
                             prov mdl)))
          (when (and (bufferp buf) (buffer-live-p buf)
                     (stringp transcript) (not (string-empty-p transcript)))
            ;; The compose area is the end of the buffer and is never
            ;; sealed; the history above it is, and stays that way.
            (with-current-buffer buf
              (goto-char (point-max))
              (insert cmacs-gowl-bar-assistant-seed-header transcript))
            (when (and cmacs-gowl-bar-assistant-send-on-open
                       (fboundp 'cmacs-ai-chat-send-compose))
              (with-current-buffer buf
                (cmacs-ai-chat-send-compose))))
          buf))
    (error
     (message "cmacs-gowl-bar-assistant: could not open a chat: %s"
              (error-message-string err))
     nil)))

;;;###autoload
(defun cmacs-gowl-bar-assistant-open-in-chat (&optional provider model transcript)
  "Continue the bar assistant's conversation in a cmacs-ai chat buffer.

PROVIDER and MODEL are strings (nil or empty for the defaults); an
unknown provider falls back to the default.  TRANSCRIPT is the bar's
conversation as `User: ...' / `Assistant: ...' paragraphs; it is put in
the compose area after `cmacs-gowl-bar-assistant-seed-header', and sent
only when `cmacs-gowl-bar-assistant-send-on-open' says so.

Returns t at once: the buffer opens from a timer, because this runs
through `emacsctl eval' on the compositor's thread under --gowl."
  (run-at-time 0 nil #'cmacs-gowl-bar-assistant--open
               provider model transcript)
  t)

(provide 'cmacs-gowl-bar-assistant)

;;; cmacs-gowl-bar-assistant.el ends here
