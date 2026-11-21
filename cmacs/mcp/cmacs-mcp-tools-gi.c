/*
 * cmacs-mcp-tools-gi.c — the `gi_call' tool
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * `gi_call' calls any introspected C function with caller-supplied
 * arguments.  It is in the privileged set, and stays a hand-written
 * handler so that a change to it is reviewed as a change to that set.
 *
 * The other tools that used to be registered here
 * (gi_list_namespaces, gi_describe and gi_list_functions)
 * are registry tools now (lisp/cmacs/cmacs-gi-tools.el), published
 * by cmacs-mcp-tools-brigade.c; their C handlers were deleted.  What
 * they promised a client is frozen in
 * test/cmacs/data/mcp-wire-schema.json.
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

  ns = json_object_get_string_member_with_default (arguments, "namespace", NULL);
  func = json_object_get_string_member_with_default (arguments, "function", NULL);
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
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GI */
