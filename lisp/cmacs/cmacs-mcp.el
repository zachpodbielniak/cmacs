;;; cmacs-mcp.el --- MCP server support for CMacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp support for the CMacs MCP server.  The C-level MCP server
;; starts automatically at init; this file provides `cmacs-mcp-mode',
;; a global minor mode that enables buffer change notifications so
;; MCP resource subscriptions stay up to date.

;;; Code:

(declare-function cmacs-mcp-server-p "cmacs-mcp.c")
(declare-function cmacs-mcp-socket-path "cmacs-mcp.c")
(declare-function cmacs-mcp-session-count "cmacs-mcp.c")
(declare-function cmacs-mcp-start "cmacs-mcp.c")
(declare-function cmacs-mcp-stop "cmacs-mcp.c")

(defgroup cmacs-mcp nil
  "CMacs MCP server settings."
  :group 'cmacs
  :prefix "cmacs-mcp-")

(defcustom cmacs-mcp-workspace-root nil
  "Workspace root directory for the MCP `project_*' file tools.

When nil, the root is auto-detected: the project.el root of the
current project, falling back to `default-directory'.  Set this to
pin a remote MCP \"copilot\" agent to a specific project tree."
  :type '(choice (const :tag "Auto-detect" nil) directory)
  :group 'cmacs-mcp)

(defcustom cmacs-mcp-workspace-confine t
  "When non-nil, confine MCP `project_*' file tools to the workspace.

Paths handed to `project_read_file', `project_write_file' and the
other workspace tools are resolved against the workspace root and
rejected if they escape it.  Set to nil only for a fully trusted
local client."
  :type 'boolean
  :group 'cmacs-mcp)

;;;###autoload
(define-minor-mode cmacs-mcp-mode
  "Global minor mode for CMacs MCP buffer change notifications.

When enabled, buffer modifications are tracked so MCP resource
subscriptions (e.g. buffer://) receive update notifications."
  :global t
  :lighter " MCP"
  :group 'cmacs-mcp
  (if cmacs-mcp-mode
      (add-hook 'after-change-functions #'cmacs-mcp--after-change)
    (remove-hook 'after-change-functions #'cmacs-mcp--after-change)))

(defvar cmacs-mcp--change-timer nil
  "Timer for debouncing buffer change notifications.")

(defun cmacs-mcp--after-change (_beg _end _len)
  "Hook function for `after-change-functions'.
Debounces notifications to avoid flooding MCP clients on rapid edits."
  (when (and (cmacs-mcp-server-p)
             (> (cmacs-mcp-session-count) 0))
    (when cmacs-mcp--change-timer
      (cancel-timer cmacs-mcp--change-timer))
    (setq cmacs-mcp--change-timer
          (run-with-idle-timer 0.5 nil #'cmacs-mcp--notify-change
                               (current-buffer)))))

(defun cmacs-mcp--notify-change (buffer)
  "Send a buffer change notification for BUFFER to MCP clients."
  (setq cmacs-mcp--change-timer nil)
  (when (and (buffer-live-p buffer)
             (cmacs-mcp-server-p))
    ;; The C layer will pick this up via resource update notifications.
    ;; For now this is a placeholder; the actual notification mechanism
    ;; requires calling mcp_server_notify_resource_updated() from C.
    ;; Use eval to trigger it:
    (ignore buffer)))

(defun cmacs-mcp-status ()
  "Display MCP server status in the echo area."
  (interactive)
  (if (cmacs-mcp-server-p)
      (message "MCP server: running on %s (%d sessions)"
               (cmacs-mcp-socket-path)
               (cmacs-mcp-session-count))
    (message "MCP server: not running")))

(provide 'cmacs-mcp)

;;; cmacs-mcp.el ends here
