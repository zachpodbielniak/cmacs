/*
 * cmacs-mcp-tools-brigade.c — MCP publication for brigade tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Publishes every capability registered through `cmacs-brigade-deftool'
 * onto an McpServer, which is the third of the three surfaces a single
 * registration reaches (the other two being in-process agents, handled
 * in cmacs-brigade-tools.el, and CLI agents, which come through the
 * relay and end up here too).
 *
 * Registration is dynamic by necessity.  cmacs_mcp_register_all_tools()
 * runs once per session, but a user's init file — or a package loaded
 * an hour later — can register a tool at any point.  So this walks the
 * live registry at session-creation time, and a hook re-announces the
 * tool list to already-connected clients when it grows.
 *
 * Handlers route through the Elisp dispatcher, so an MCP client and an
 * in-process agent execute the identical handler with the identical
 * confirmation and hook behaviour.  Two paths into one implementation
 * is the whole point; two implementations would drift.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP
#ifdef HAVE_CMACS_AI_BRIGADE

#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-brigade.h"

#include <mcp.h>
#include <glib.h>
#include <json-glib/json-glib.h>
#include <string.h>

/* Escape for interpolation into a quoted Lisp string.  Every argument
 * here is untrusted input from an external agent, so this is the
 * boundary that keeps it data rather than code. */
static gchar *
escape_for_lisp (const gchar *s)
{
  GString *out;
  const gchar *p;

  if (s == NULL) return g_strdup ("");
  out = g_string_sized_new (strlen (s) + 8);
  for (p = s; *p; p++)
    {
      if (*p == '\\' || *p == '"')
        g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  return g_string_free (out, FALSE);
}

/* One handler for every brigade tool.  The tool name arrives as MCP's
 * `name' argument, so a single handler can serve the whole registry
 * instead of generating a closure per tool. */
static McpToolResult *
handle_brigade_tool (McpServer *server, const gchar *name,
                     JsonObject *arguments, gpointer user_data)
{
  g_autoptr (JsonNode) node = NULL;
  g_autofree gchar *args_json = NULL;
  g_autofree gchar *esc_name = NULL;
  g_autofree gchar *esc_args = NULL;
  g_autofree gchar *expr = NULL;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;
  McpToolResult *result;

  (void) server;
  (void) user_data;

  /* Re-serialise the arguments rather than walking them: the Elisp side
   * already has a JSON parser and a coercion table, and duplicating
   * either here would give MCP callers subtly different type handling
   * from in-process agents. */
  node = json_node_new (JSON_NODE_OBJECT);
  json_node_set_object (node, arguments);
  args_json = json_to_string (node, FALSE);

  esc_name = escape_for_lisp (name);
  esc_args = escape_for_lisp (args_json);
  /* The agent argument is "mcp": an external client is not one of the
   * brigade's own agents, and labelling it as such in the audit trail
   * matters when working out who called what. */
  expr = g_strdup_printf ("(cmacs-brigade-call-tool \"%s\" \"%s\" \"mcp\")",
                          esc_name, esc_args);

  res = cmacs_dispatch_eval_string (expr, &err);
  if (res == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, err ? err->message
                                : "brigade tool dispatch failed");
      return result;
    }

  /* `cmacs-brigade-call-tool' returns "Error: ..." rather than
   * signalling, following ai-glib's soft-error convention, so surface
   * that as an MCP error while still handing back the text. */
  result = mcp_tool_result_new (g_str_has_prefix (res, "Error: "));
  mcp_tool_result_add_text (result, res);
  return result;
}

/* Build the JSON Schema for one tool from its stored parameter array. */
static JsonNode *
schema_for_tool (const CmacsBrigadeTool *tool)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  JsonArray *params = NULL;
  guint i, n;

  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "type");
  json_builder_add_string_value (builder, "object");

  json_builder_set_member_name (builder, "properties");
  json_builder_begin_object (builder);

  if (tool->params_json != NULL
      && json_parser_load_from_data (parser, tool->params_json, -1, NULL)
      && JSON_NODE_HOLDS_ARRAY (json_parser_get_root (parser)))
    params = json_node_get_array (json_parser_get_root (parser));

  n = params ? json_array_get_length (params) : 0;
  for (i = 0; i < n; i++)
    {
      JsonObject *p = json_array_get_object_element (params, i);
      const gchar *pname, *ptype, *pdesc;

      if (p == NULL) continue;
      pname = json_object_get_string_member_with_default (p, "name", NULL);
      if (pname == NULL) continue;
      ptype = json_object_get_string_member_with_default (p, "type", "string");
      pdesc = json_object_get_string_member_with_default (p, "description", "");

      json_builder_set_member_name (builder, pname);
      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "type");
      json_builder_add_string_value (builder, ptype);
      json_builder_set_member_name (builder, "description");
      json_builder_add_string_value (builder, pdesc);
      json_builder_end_object (builder);
    }
  json_builder_end_object (builder);   /* properties */

  json_builder_set_member_name (builder, "required");
  json_builder_begin_array (builder);
  for (i = 0; i < n; i++)
    {
      JsonObject *p = json_array_get_object_element (params, i);
      const gchar *pname;

      if (p == NULL) continue;
      if (!json_object_get_boolean_member_with_default (p, "required", FALSE))
        continue;
      pname = json_object_get_string_member_with_default (p, "name", NULL);
      if (pname != NULL) json_builder_add_string_value (builder, pname);
    }
  json_builder_end_array (builder);
  json_builder_end_object (builder);

  return json_builder_get_root (builder);
}

/* True when SERVER already exposes a tool called NAME.
 *
 * mcp_server_add_tool replaces on collision, so without this check a
 * user registering a tool called "eval" would silently take over the
 * real eval for every MCP client -- a privilege escalation dressed up
 * as a naming accident. */
static gboolean
server_has_tool (McpServer *server, const gchar *name)
{
  GList *tools = mcp_server_list_tools (server);
  GList *l;
  gboolean found = FALSE;

  for (l = tools; l != NULL; l = l->next)
    {
      const gchar *existing = mcp_tool_get_name (MCP_TOOL (l->data));
      if (existing != NULL && strcmp (existing, name) == 0)
        {
          found = TRUE;
          break;
        }
    }
  g_list_free (tools);
  return found;
}

static void
publish_one (const CmacsBrigadeTool *tool, gpointer user_data)
{
  McpServer *server = user_data;
  g_autoptr (McpTool) mt = NULL;
  g_autoptr (JsonNode) schema = NULL;

  if (server_has_tool (server, tool->name))
    {
      g_warning ("cmacs-brigade: tool `%s' shadows a built-in MCP tool "
                 "and was not published; rename it", tool->name);
      return;
    }

  mt = mcp_tool_new (tool->name, tool->description);
  schema = schema_for_tool (tool);

  mcp_tool_set_input_schema (mt, schema);
  /* The classification the policy filter uses is the same one the model
   * sees, so a tool cannot look harmless to a client while being
   * treated as destructive by the filter (or vice versa). */
  mcp_tool_set_read_only_hint (mt, !tool->destructive);
  mcp_tool_set_destructive_hint (mt, tool->destructive);

  mcp_server_add_tool (server, mt, handle_brigade_tool, NULL, NULL);
}

void
cmacs_mcp_tools_brigade_register (McpServer *server)
{
  cmacs_brigade_registry_init ();
  cmacs_brigade_registry_foreach (publish_one, server);
}

#endif /* HAVE_CMACS_AI_BRIGADE */
#endif /* HAVE_CMACS_MCP */
