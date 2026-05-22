/*
 * cmacs-mcp-prompts.c — MCP prompt templates for Emacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* ── debug_session ────────────────────────────────────────────────── */

static McpPromptResult *
handle_debug_session (McpServer  *server,
                      const gchar *name,
                      GHashTable  *arguments,
                      gpointer     user_data)
{
  const gchar *error_message, *buffer;
  GString *text;
  McpPromptResult *result;
  McpPromptMessage *msg;
  g_autoptr (GError) err = NULL;

  (void) server;
  (void) name;
  (void) user_data;

  error_message = arguments
    ? g_hash_table_lookup (arguments, "error_message")
    : NULL;
  buffer = arguments
    ? g_hash_table_lookup (arguments, "buffer")
    : NULL;

  text = g_string_new ("Debug this Emacs session.\n\n");

  if (error_message != NULL)
    g_string_append_printf (text, "Error: %s\n\n", error_message);

  /* Backtrace */
  {
    g_autofree gchar *bt = cmacs_dispatch_eval (
      "(with-output-to-string (backtrace))", &err);
    if (bt != NULL)
      g_string_append_printf (text, "Backtrace:\n%s\n\n", bt);
  }

  /* Recent messages */
  {
    g_autofree gchar *msgs = cmacs_dispatch_eval (
      "(with-current-buffer \"*Messages*\""
      "  (let ((s (max (- (point-max) 1) (point-min))))"
      "    (save-excursion"
      "      (goto-char (point-max))"
      "      (forward-line -30)"
      "      (buffer-substring-no-properties (point) (point-max)))))",
      &err);
    if (msgs != NULL)
      g_string_append_printf (text, "Recent messages:\n%s\n\n", msgs);
  }

  /* Buffer content if specified */
  if (buffer != NULL)
    {
      g_autofree gchar *expr = g_strdup_printf (
        "(with-current-buffer \"%s\""
        "  (format \"Buffer: %%s\\nMode: %%s\\nFile: %%s\\n\\n%%s\""
        "    (buffer-name)"
        "    (symbol-name major-mode)"
        "    (or (buffer-file-name) \"(no file)\")"
        "    (buffer-substring-no-properties (point-min)"
        "      (min (point-max) (+ (point-min) 10000)))))",
        buffer);
      g_autofree gchar *buf_info = cmacs_dispatch_eval (expr, &err);
      if (buf_info != NULL)
        g_string_append_printf (text, "%s\n\n", buf_info);
    }

  /* Process status */
  {
    g_autofree gchar *status = cmacs_dispatch_eval (
      "(format \"PID: %d, Uptime: %s, Version: %s\""
      "  (emacs-pid) (emacs-uptime) emacs-version)",
      &err);
    if (status != NULL)
      g_string_append_printf (text, "Process: %s\n", status);
  }

  result = mcp_prompt_result_new (
    "Debug session context for the running Emacs instance");
  msg = mcp_prompt_message_new (MCP_ROLE_USER);
  mcp_prompt_message_add_text (msg, text->str);
  mcp_prompt_result_add_message (result, msg);

  g_string_free (text, TRUE);
  mcp_prompt_message_unref (msg);

  return result;
}

/* ── code_review ──────────────────────────────────────────────────── */

static McpPromptResult *
handle_code_review (McpServer  *server,
                    const gchar *name,
                    GHashTable  *arguments,
                    gpointer     user_data)
{
  const gchar *buffer;
  GString *text;
  McpPromptResult *result;
  McpPromptMessage *msg;
  g_autoptr (GError) err = NULL;

  (void) server;
  (void) name;
  (void) user_data;

  buffer = arguments
    ? g_hash_table_lookup (arguments, "buffer")
    : NULL;

  if (buffer == NULL)
    buffer = "(current-buffer)";

  text = g_string_new ("Review the following code.\n\n");

  {
    g_autofree gchar *expr = g_strdup_printf (
      "(with-current-buffer \"%s\""
      "  (format \"File: %%s\\nMode: %%s\\nSize: %%d bytes\\n\\n%%s\""
      "    (or (buffer-file-name) (buffer-name))"
      "    (symbol-name major-mode)"
      "    (buffer-size)"
      "    (buffer-substring-no-properties (point-min) (point-max))))",
      buffer);
    g_autofree gchar *content = cmacs_dispatch_eval (expr, &err);
    if (content != NULL)
      g_string_append (text, content);
    else
      g_string_append (text, "(could not read buffer)");
  }

  result = mcp_prompt_result_new (
    "Code review context for an Emacs buffer");
  msg = mcp_prompt_message_new (MCP_ROLE_USER);
  mcp_prompt_message_add_text (msg, text->str);
  mcp_prompt_result_add_message (result, msg);

  g_string_free (text, TRUE);
  mcp_prompt_message_unref (msg);

  return result;
}

#ifdef HAVE_CMACS_GOWL
/* ── gowl_layout ──────────────────────────────────────────────────── */

static McpPromptResult *
handle_gowl_layout (McpServer  *server,
                    const gchar *name,
                    GHashTable  *arguments,
                    gpointer     user_data)
{
  GString *text;
  McpPromptResult *result;
  McpPromptMessage *msg;
  g_autoptr (GError) err = NULL;

  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;

  text = g_string_new (
    "Current gowl Wayland compositor state.\n\n");

  {
    g_autofree gchar *layout = cmacs_dispatch_eval (
      "(prin1-to-string (gowl-get-layout))", &err);
    if (layout != NULL)
      g_string_append_printf (text, "Layout: %s\n\n", layout);
  }

  {
    g_autofree gchar *clients = cmacs_dispatch_gowl_list_clients (&err);
    if (clients != NULL)
      g_string_append_printf (text, "Clients:\n%s\n\n", clients);
  }

  {
    g_autofree gchar *monitors = cmacs_dispatch_gowl_list_monitors (&err);
    if (monitors != NULL)
      g_string_append_printf (text, "Monitors:\n%s\n\n", monitors);
  }

  {
    g_autofree gchar *workspaces = cmacs_dispatch_eval (
      "(prin1-to-string (gowl-workspace-list))", &err);
    if (workspaces != NULL)
      g_string_append_printf (text, "Workspaces:\n%s\n", workspaces);
  }

  result = mcp_prompt_result_new (
    "Compositor layout context for the running gowl session");
  msg = mcp_prompt_message_new (MCP_ROLE_USER);
  mcp_prompt_message_add_text (msg, text->str);
  mcp_prompt_result_add_message (result, msg);

  g_string_free (text, TRUE);
  mcp_prompt_message_unref (msg);

  return result;
}
#endif /* HAVE_CMACS_GOWL */

#ifdef HAVE_CMACS_PODOMATION
/* ── automation_author ────────────────────────────────────────────── */

static McpPromptResult *
handle_automation_author (McpServer  *server,
                          const gchar *name,
                          GHashTable  *arguments,
                          gpointer     user_data)
{
  GString *text;
  McpPromptResult *result;
  McpPromptMessage *msg;
  g_autoptr (GError) err = NULL;

  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;

  text = g_string_new (
    "Author a podomation automation. The podomation engine reacts to "
    "events with pods written in its DSL.\n\n");

  {
    g_autofree gchar *modules = cmacs_dispatch_eval (
      "(prin1-to-string (cmacs-podomation-list-modules))", &err);
    if (modules != NULL)
      g_string_append_printf (text, "Loaded modules:\n%s\n\n", modules);
  }

  {
    g_autofree gchar *pods = cmacs_dispatch_eval (
      "(prin1-to-string (cmacs-podomation-list-pods))", &err);
    if (pods != NULL)
      g_string_append_printf (text, "Active pods:\n%s\n\n", pods);
  }

  {
    g_autofree gchar *running = cmacs_dispatch_eval (
      "(if (cmacs-podomation-running-p) \"running\" \"stopped\")",
      &err);
    if (running != NULL)
      g_string_append_printf (text, "Engine: %s\n", running);
  }

  result = mcp_prompt_result_new (
    "Authoring context for the podomation automation engine");
  msg = mcp_prompt_message_new (MCP_ROLE_USER);
  mcp_prompt_message_add_text (msg, text->str);
  mcp_prompt_result_add_message (result, msg);

  g_string_free (text, TRUE);
  mcp_prompt_message_unref (msg);

  return result;
}
#endif /* HAVE_CMACS_PODOMATION */

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_register_prompts (McpServer *server)
{
  McpPrompt *prompt;

  /* debug_session */
  prompt = mcp_prompt_new ("debug_session",
    "Start a debug session with full Emacs context: backtrace, "
    "messages, buffer content, and process info.");
  mcp_prompt_add_argument_full (prompt, "error_message",
    "Error message or symptom to investigate", FALSE);
  mcp_prompt_add_argument_full (prompt, "buffer",
    "Buffer name to include in context", FALSE);
  mcp_server_add_prompt (server, prompt,
    handle_debug_session, NULL, NULL);
  g_object_unref (prompt);

  /* code_review */
  prompt = mcp_prompt_new ("code_review",
    "Review code in an Emacs buffer with file info and content.");
  mcp_prompt_add_argument_full (prompt, "buffer",
    "Buffer name to review (defaults to current buffer)", FALSE);
  mcp_server_add_prompt (server, prompt,
    handle_code_review, NULL, NULL);
  g_object_unref (prompt);

#ifdef HAVE_CMACS_GOWL
  /* gowl_layout */
  prompt = mcp_prompt_new ("gowl_layout",
    "Compositor state context: current layout, clients, monitors, "
    "and workspaces.");
  mcp_server_add_prompt (server, prompt,
    handle_gowl_layout, NULL, NULL);
  g_object_unref (prompt);
#endif

#ifdef HAVE_CMACS_PODOMATION
  /* automation_author */
  prompt = mcp_prompt_new ("automation_author",
    "Authoring context for podomation: loaded modules, active pods, "
    "and engine status.");
  mcp_server_add_prompt (server, prompt,
    handle_automation_author, NULL, NULL);
  g_object_unref (prompt);
#endif
}

#endif /* HAVE_CMACS_MCP */
