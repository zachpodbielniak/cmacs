/*
 * cmacs-mcp-tools-process.c — Process management MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* ── list_processes ───────────────────────────────────────────────── */

static McpToolResult *
handle_list_processes (McpServer   *server,
                       const gchar *name,
                       JsonObject  *arguments,
                       gpointer     user_data)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;

  result_str = cmacs_dispatch_eval (
    "(mapconcat"
    "  (lambda (p)"
    "    (format \"%s|%s|%s|%s\""
    "      (process-name p)"
    "      (symbol-name (process-status p))"
    "      (or (and (process-buffer p) (buffer-name (process-buffer p))) \"\")"
    "      (mapconcat #'identity (process-command p) \" \")))"
    "  (process-list) \"\\n\")",
    &error);

  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── send_to_process ──────────────────────────────────────────────── */

static McpToolResult *
handle_send_to_process (McpServer   *server,
                        const gchar *name,
                        JsonObject  *arguments,
                        gpointer     user_data)
{
  const gchar *process_name, *input;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *escaped = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  process_name = json_object_get_string_member (arguments, "process");
  input = json_object_get_string_member (arguments, "input");
  if (process_name == NULL || input == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required arguments: process, input");
      return result;
    }

  escaped = g_strescape (input, NULL);
  expr = g_strdup_printf (
    "(process-send-string \"%s\" \"%s\") t",
    process_name, escaped);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_process_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* list_processes */
  tool = mcp_tool_new ("list_processes",
    "List all Emacs subprocesses with name, status, buffer, and command.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_processes, NULL, NULL);
  g_object_unref (tool);

  /* send_to_process */
  tool = mcp_tool_new ("send_to_process",
    "Send a string to a running subprocess (e.g. shell input).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"process\":{\"type\":\"string\",\"description\":\"Process name\"},"
    "\"input\":{\"type\":\"string\",\"description\":\"String to send\"}"
    "},\"required\":[\"process\",\"input\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_send_to_process, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
