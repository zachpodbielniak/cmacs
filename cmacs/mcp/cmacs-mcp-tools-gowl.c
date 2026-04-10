/*
 * cmacs-mcp-tools-gowl.c — Gowl Wayland compositor MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Direct C dispatch to the gowl compositor, bypassing Elisp for
 * performance.  Uses the cmacs_dispatch_gowl_*() functions from
 * cmacs-eval-dispatch.c.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_GOWL)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Helper: dispatch a gowl function returning gchar*, wrap in result. */
static McpToolResult *
gowl_result (gchar *str, GError *error)
{
  McpToolResult *result;
  if (str == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        error ? error->message : "Unknown gowl error");
    }
  else
    {
      result = mcp_tool_result_new (FALSE);
      mcp_tool_result_add_text (result, str);
      g_free (str);
    }
  return result;
}

/* ── Tool handlers ────────────────────────────────────────────────── */

static McpToolResult *
handle_gowl_list_clients (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_list_clients (&error), error);
}

static McpToolResult *
handle_gowl_focused_client (McpServer *s, const gchar *n,
                             JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_focused_client (&error), error);
}

static McpToolResult *
handle_gowl_spawn (McpServer *s, const gchar *n,
                   JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *command;
  (void) s; (void) n; (void) u;
  command = json_object_get_string_member (a, "command");
  if (command == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: command");
      return r;
    }
  return gowl_result (cmacs_dispatch_gowl_spawn (command, &error), error);
}

static McpToolResult *
handle_gowl_list_monitors (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_list_monitors (&error), error);
}

static McpToolResult *
handle_gowl_list_keybinds (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_list_keybinds (&error), error);
}

static McpToolResult *
handle_gowl_find_client (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *pattern, *by;
  (void) s; (void) n; (void) u;
  pattern = json_object_get_string_member (a, "pattern");
  by = json_object_get_string_member (a, "by");
  if (pattern == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: pattern");
      return r;
    }
  return gowl_result (
    cmacs_dispatch_gowl_find_client (pattern, by ? by : "app-id", &error),
    error);
}

static McpToolResult *
handle_gowl_reload_config (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_reload_config (&error), error);
}

static McpToolResult *
handle_gowl_lock (McpServer *s, const gchar *n,
                   JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_lock (&error), error);
}

static McpToolResult *
handle_gowl_unlock (McpServer *s, const gchar *n,
                     JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_unlock (&error), error);
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_gowl_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("gowl_list_clients",
    "List all Wayland clients (JSON array with id, title, app-id, tags, geometry).");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_list_clients, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_focused_client",
    "Get info about the currently focused Wayland client.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_focused_client, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_spawn",
    "Spawn a command in the Wayland compositor.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"command\":{\"type\":\"string\",\"description\":\"Shell command to spawn\"}"
    "},\"required\":[\"command\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_spawn, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_list_monitors",
    "List monitors (JSON array with name, geometry, mode, scale, layout).");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_list_monitors, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_list_keybinds",
    "List all compositor keybinds.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_list_keybinds, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_find_client",
    "Find a Wayland client by app-id or title pattern.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"pattern\":{\"type\":\"string\",\"description\":\"Search pattern\"},"
    "\"by\":{\"type\":\"string\",\"enum\":[\"app-id\",\"title\"],"
    "\"description\":\"Search field (default: app-id)\"}"
    "},\"required\":[\"pattern\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_find_client, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_reload_config",
    "Reload the gowl compositor configuration from YAML.");
  mcp_server_add_tool (server, tool, handle_gowl_reload_config, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_lock",
    "Lock the compositor screen.");
  mcp_server_add_tool (server, tool, handle_gowl_lock, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_unlock",
    "Unlock the compositor screen.");
  mcp_server_add_tool (server, tool, handle_gowl_unlock, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GOWL */
