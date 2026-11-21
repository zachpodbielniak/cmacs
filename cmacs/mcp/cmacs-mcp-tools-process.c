/*
 * cmacs-mcp-tools-process.c — the `send_to_process' tool
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * `send_to_process' types caller-supplied input into a subprocess.  It is
 * in the privileged set, and stays a hand-written handler so that a
 * change to it is reviewed as a change to that set.
 *
 * The other tools that used to be registered here (list_processes)
 * are registry tools now (lisp/cmacs/cmacs-process-tools.el), published
 * by cmacs-mcp-tools-brigade.c; their C handlers were deleted.  What
 * they promised a client is frozen in
 * test/cmacs/data/mcp-wire-schema.json.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

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
  g_autofree gchar *eproc = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  process_name = json_object_get_string_member_with_default (arguments, "process", NULL);
  input = json_object_get_string_member_with_default (arguments, "input", NULL);
  if (process_name == NULL || input == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required arguments: process, input");
      return result;
    }

  escaped = cmacs_dispatch_lisp_escape (input);
  eproc = cmacs_dispatch_lisp_escape (process_name);
  expr = g_strdup_printf (
    "(progn (process-send-string \"%s\" \"%s\") t)",
    eproc, escaped);

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
