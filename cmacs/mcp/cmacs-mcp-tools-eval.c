/*
 * cmacs-mcp-tools-eval.c — the `eval' tool
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * `eval' runs caller-supplied Lisp.  It is the first name in the
 * privileged set the brigade's allowlist keeps from agents, and stays a
 * hand-written handler so that a change to it is reviewed as a change to
 * that set.
 *
 * The other tools that used to be registered here (describe_function,
 * describe_variable, apropos and completions) are registry tools now
 * (lisp/cmacs/cmacs-describe-tools.el), published by
 * cmacs-mcp-tools-brigade.c; their C handlers were deleted.  What
 * they promised a client is frozen in
 * test/cmacs/data/mcp-wire-schema.json.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* ── eval ─────────────────────────────────────────────────────────── */

static McpToolResult *
handle_eval (McpServer   *server,
             const gchar *name,
             JsonObject  *arguments,
             gpointer     user_data)
{
  const gchar *expression;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  expression = json_object_get_string_member_with_default (arguments, "expression", NULL);
  if (expression == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: expression");
      return result;
    }

  result_str = cmacs_dispatch_eval (expression, &error);
  if (result_str == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, error->message);
      return result;
    }

  result = mcp_tool_result_new (FALSE);
  mcp_tool_result_add_text (result, result_str);
  return result;
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_eval_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* eval */
  tool = mcp_tool_new ("eval",
    "Evaluate an Emacs Lisp expression and return the printed result. "
    "This is the universal gateway to all Emacs functionality.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"expression\":{\"type\":\"string\","
    "\"description\":\"Elisp expression to evaluate\"}"
    "},\"required\":[\"expression\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_eval, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
