/*
 * cmacs-mcp-tools-input.c — Input simulation MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* ── send_keys ────────────────────────────────────────────────────── */

static McpToolResult *
handle_send_keys (McpServer   *server,
                  const gchar *name,
                  JsonObject  *arguments,
                  gpointer     user_data)
{
  const gchar *keys;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  keys = json_object_get_string_member (arguments, "keys");
  if (keys == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: keys");
      return result;
    }

  expr = g_strdup_printf (
    "(execute-kbd-macro (kbd \"%s\")) t", keys);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── execute_command ──────────────────────────────────────────────── */

static McpToolResult *
handle_execute_command (McpServer   *server,
                        const gchar *name,
                        JsonObject  *arguments,
                        gpointer     user_data)
{
  const gchar *command;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  command = json_object_get_string_member (arguments, "command");
  if (command == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: command");
      return result;
    }

  expr = g_strdup_printf (
    "(call-interactively '%s)", command);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_input_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* send_keys */
  tool = mcp_tool_new ("send_keys",
    "Send a key sequence to Emacs (e.g. \"C-x C-f\", \"M-x\", \"RET\").");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"keys\":{\"type\":\"string\","
    "\"description\":\"Key sequence in Emacs notation (e.g. C-x C-s)\"}"
    "},\"required\":[\"keys\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_send_keys, NULL, NULL);
  g_object_unref (tool);

  /* execute_command */
  tool = mcp_tool_new ("execute_command",
    "Execute an interactive Emacs command (M-x equivalent).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"command\":{\"type\":\"string\","
    "\"description\":\"Command name (e.g. save-buffer, find-file)\"}"
    "},\"required\":[\"command\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_execute_command, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
