/*
 * cmacs-mcp-tools-gi.c — GObject Introspection MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_GI)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* ── gi_call ──────────────────────────────────────────────────────── */

static McpToolResult *
handle_gi_call (McpServer   *server,
                const gchar *name,
                JsonObject  *arguments,
                gpointer     user_data)
{
  const gchar *ns, *func;
  JsonArray *args_array;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  ns = json_object_get_string_member (arguments, "namespace");
  func = json_object_get_string_member (arguments, "function");
  if (ns == NULL || func == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required arguments: namespace, function");
      return result;
    }

  args_array = json_object_has_member (arguments, "args")
    ? json_object_get_array_member (arguments, "args")
    : NULL;

  if (args_array != NULL)
    {
      guint n = json_array_get_length (args_array);
      g_autofree const gchar **c_args = g_new0 (const gchar *, n + 1);
      /* Collect string representations of args. */
      g_autofree gchar **owned = g_new0 (gchar *, n + 1);
      for (guint i = 0; i < n; i++)
        {
          JsonNode *node = json_array_get_element (args_array, i);
          owned[i] = json_node_get_string (node)
            ? g_strdup (json_node_get_string (node))
            : json_to_string (node, FALSE);
          c_args[i] = owned[i];
        }
      result_str = cmacs_dispatch_gi_call (ns, func, c_args, n, &error);
      for (guint i = 0; i < n; i++)
        g_free (owned[i]);
    }
  else
    result_str = cmacs_dispatch_gi_call (ns, func, NULL, 0, &error);

  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── gi_list_namespaces ───────────────────────────────────────────── */

static McpToolResult *
handle_gi_list_namespaces (McpServer   *server,
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
    "(mapconcat #'identity (gi-loaded-namespaces) \"\\n\")",
    &error);

  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── gi_describe ──────────────────────────────────────────────────── */

static McpToolResult *
handle_gi_describe (McpServer   *server,
                    const gchar *name,
                    JsonObject  *arguments,
                    gpointer     user_data)
{
  const gchar *ns, *symbol;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  ns = json_object_get_string_member (arguments, "namespace");
  symbol = json_object_get_string_member (arguments, "symbol");
  if (ns == NULL || symbol == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required arguments: namespace, symbol");
      return result;
    }

  expr = g_strdup_printf (
    "(gi-describe \"%s\" \"%s\")", ns, symbol);
  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── gi_list_functions ────────────────────────────────────────────── */

static McpToolResult *
handle_gi_list_functions (McpServer   *server,
                          const gchar *name,
                          JsonObject  *arguments,
                          gpointer     user_data)
{
  const gchar *ns;
  g_auto (GStrv) funcs = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  ns = json_object_get_string_member (arguments, "namespace");
  if (ns == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: namespace");
      return result;
    }

  funcs = cmacs_dispatch_gi_list_functions (ns);
  if (funcs == NULL || funcs[0] == NULL)
    {
      result = mcp_tool_result_new (FALSE);
      mcp_tool_result_add_text (result, "(no functions)");
      return result;
    }

  {
    g_autofree gchar *joined = g_strjoinv ("\n", funcs);
    result = mcp_tool_result_new (FALSE);
    mcp_tool_result_add_text (result, joined);
    return result;
  }
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_gi_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* gi_call */
  tool = mcp_tool_new ("gi_call",
    "Call a GObject Introspection function. "
    "Requires the namespace to be loaded (use gi_require first via eval).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"namespace\":{\"type\":\"string\",\"description\":\"GI namespace (e.g. Gtk, Gio)\"},"
    "\"function\":{\"type\":\"string\",\"description\":\"Function name\"},"
    "\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
    "\"description\":\"Function arguments as strings\"}"
    "},\"required\":[\"namespace\",\"function\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gi_call, NULL, NULL);
  g_object_unref (tool);

  /* gi_list_namespaces */
  tool = mcp_tool_new ("gi_list_namespaces",
    "List loaded GObject Introspection namespaces.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gi_list_namespaces, NULL, NULL);
  g_object_unref (tool);

  /* gi_describe */
  tool = mcp_tool_new ("gi_describe",
    "Describe a type or function in a GI namespace.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"namespace\":{\"type\":\"string\",\"description\":\"GI namespace\"},"
    "\"symbol\":{\"type\":\"string\",\"description\":\"Type or function name\"}"
    "},\"required\":[\"namespace\",\"symbol\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gi_describe, NULL, NULL);
  g_object_unref (tool);

  /* gi_list_functions */
  tool = mcp_tool_new ("gi_list_functions",
    "List all functions in a GI namespace.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"namespace\":{\"type\":\"string\",\"description\":\"GI namespace\"}"
    "},\"required\":[\"namespace\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gi_list_functions, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GI */
