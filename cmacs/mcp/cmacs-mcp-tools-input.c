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

/* Seconds send_keys waits before giving up on a key sequence that has
   left Emacs reading input.  See handle_send_keys. */
#define CMACS_MCP_SEND_KEYS_TIMEOUT 5

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

  keys = json_object_get_string_member_with_default (arguments, "keys", NULL);
  if (keys == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: keys");
      return result;
    }

  /* send_keys is the one tool that deliberately simulates a user, so
     it re-enables the interaction cmacs_dispatch_eval inhibits: a
     macro like "C-x C-f foo RET" has to be able to enter the
     minibuffer, and the macro itself supplies the answer.  When the
     macro runs dry while something is still reading input, Emacs falls
     back to waiting for a *real* key -- which would wedge the MCP
     request (and leave the editor in a recursive edit) forever.
     with-timeout's timer runs inside that read and unwinds instead,
     turning the wedge into an error reply. */
  expr = g_strdup_printf (
    "(with-timeout (%d (error \"send_keys: key sequence left Emacs"
    " waiting for input\"))"
    " (let ((inhibit-interaction nil))"
    "  (execute-kbd-macro (kbd \"%s\"))"
    "  t))",
    CMACS_MCP_SEND_KEYS_TIMEOUT, keys);

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

  command = json_object_get_string_member_with_default (arguments, "command", NULL);
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
