;;; cmacs-ai-call.el --- Generic programmatic AI calls  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Config-friendly wrappers around the cmacs-ai C primitives for making
;; one-shot AI calls -- with or without tools -- from Elisp and using the
;; result programmatically.  This is the layer a user config reaches for.
;;
;; Plain call (no tools), returns a string:
;;
;;   (cmacs-ai-call "Summarise this commit in one line: ...")
;;   (cmacs-ai-call "why is the sky blue?" :provider 'ollama :model "llama3.2")
;;
;; Agentic call with the built-in tools (bash/read/write/edit/glob/grep/
;; ls/web_fetch) -- the model can act, and the final answer is returned:
;;
;;   (cmacs-ai-call "What files are in my home directory?" :builtin-tools t)
;;
;; Call with a custom Elisp tool.  The tool's *return value* (a string) is
;; handed back to the model, so it can use the result:
;;
;;   (cmacs-ai-call
;;    "How many lines are in ~/.bashrc?"
;;    :tools (list (cmacs-ai-define-tool
;;                  "count_lines" "Count the lines in a file"
;;                  '(("path" "string" "Absolute file path" t))
;;                  (lambda (_name input _id)
;;                    (let* ((args (json-parse-string input :object-type 'alist))
;;                           (path (alist-get 'path args)))
;;                      (number-to-string
;;                       (with-temp-buffer
;;                         (insert-file-contents (expand-file-name path))
;;                         (count-lines (point-min) (point-max)))))))))
;;
;; Expose the cmacs MCP tool surface (buffers, windows, gowl, ...) to the
;; model with :mcp-bridge t (needs --with-cmacs-mcp).

;;; Code:

(require 'cmacs)

(defun cmacs-ai-define-tool (name description params callback)
  "Return a tool spec usable in `cmacs-ai-call' :tools.
NAME and DESCRIPTION are strings.  PARAMS is a list of parameter
descriptors, each (PNAME PTYPE PDESC REQUIRED-P) where PNAME/PTYPE/PDESC
are strings and REQUIRED-P is non-nil for a required parameter.

CALLBACK is invoked as (funcall CALLBACK NAME INPUT-JSON ID) when the
model calls the tool: NAME is the tool name, INPUT-JSON is the model's
arguments as a JSON string, ID is the tool-call id.  CALLBACK must
return a string, which is handed back to the model as the tool result;
returning nil signals a tool error to the model."
  (list name description params callback))

(defun cmacs-ai--register-tool (executor spec)
  "Register tool SPEC (from `cmacs-ai-define-tool') on EXECUTOR."
  (pcase-let ((`(,name ,description ,params ,callback) spec))
    ;; The C primitive takes PARAMS and CALLBACK as a single cons because
    ;; its arity is fixed at 4.
    (cmacs-ai-tools-register executor name description
                             (cons params callback))))

;;;###autoload
(defun cmacs-ai-call (prompt &rest keys)
  "Prompt the AI with PROMPT and return the final answer as a string.

Without tools this is a stateless single-shot call (like
`cmacs-ai-prompt-sync').  When any tool option is given, a throwaway
tool-executor is built, used for a synchronous multi-turn tool loop, and
always freed afterwards.

KEYS is a plist:
  :provider SYMBOL     provider (claude / openai / gemini / grok / ollama
                       / claude-code / opencode / claude-tmux /
                       grok-build / antigravity / cursor); nil = the
                       configured default.
  :system STRING       system prompt.
  :model STRING        model name overriding the provider's default.
  :max-tokens N        cap each turn's response length.
  :tools LIST          list of tool specs from `cmacs-ai-define-tool'.
  :builtin-tools BOOL  give the model ai-glib's built-in tools
                       (bash/read/write/edit/glob/grep/ls/web_fetch).
  :mcp-bridge BOOL     expose the cmacs MCP tool surface (needs
                       --with-cmacs-mcp).
  :search-provider X   enable a web_search tool via backend X (a symbol:
                       auto/brave/bing/duckduckgo).
  :directory DIR       run the built-in tools in DIR: relative paths
                       resolve against it and shell commands run there.
                       Without it they use Emacs's own directory, which
                       is wherever you last visited a file -- almost
                       never what the model meant by a relative path.

Note: any tool-enabled call also carries the built-in tools, since a
cmacs tool executor always includes them; custom tools are added on top.

Signals `cmacs-ai-error' on failure.  Blocks Emacs for the duration of
the call -- keep tool loops short, especially under `emacs --gowl'."
  (unless (fboundp 'cmacs-ai--call)
    (error "cmacs-ai is not available in this build (need --with-cmacs-ai)"))
  (let* ((provider (plist-get keys :provider))
         (system   (plist-get keys :system))
         (model    (plist-get keys :model))
         (maxtok   (plist-get keys :max-tokens))
         (tools    (plist-get keys :tools))
         (builtin  (plist-get keys :builtin-tools))
         (mcp      (plist-get keys :mcp-bridge))
         (search   (plist-get keys :search-provider))
         (dir      (plist-get keys :directory))
         (want-tools (or tools builtin mcp search dir)))
    (if (not want-tools)
        (cmacs-ai--call prompt provider system model nil maxtok)
      (let ((executor (cmacs-ai-tools-new)))
        (unwind-protect
            (progn
              (when mcp
                (unless (fboundp 'cmacs-ai-tools-register-mcp-bridge)
                  (error "cmacs-ai-call :mcp-bridge requires --with-cmacs-mcp"))
                (cmacs-ai-tools-register-mcp-bridge executor))
              (when search
                (cmacs-ai-tools-set-search-provider executor search))
              (when dir
                (cmacs-ai-tools-set-working-directory executor dir))
              (dolist (spec tools)
                (cmacs-ai--register-tool executor spec))
              (cmacs-ai--call prompt provider system model executor maxtok))
          (cmacs-ai-tools-free executor))))))

(provide 'cmacs-ai-call)
;;; cmacs-ai-call.el ends here
