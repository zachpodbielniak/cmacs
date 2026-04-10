/*
 * cmacs-mcp-tools-window.c — Window and frame management MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* ── list_windows ─────────────────────────────────────────────────── */

static McpToolResult *
handle_list_windows (McpServer   *server,
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
    "  (lambda (w)"
    "    (format \"%s|%s|%d|%d|%d|%d\""
    "      (window-buffer w)"
    "      (window-point w)"
    "      (window-total-height w)"
    "      (window-total-width w)"
    "      (nth 0 (window-edges w))"
    "      (nth 1 (window-edges w))))"
    "  (window-list) \"\\n\")",
    &error);

  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── list_frames ──────────────────────────────────────────────────── */

static McpToolResult *
handle_list_frames (McpServer   *server,
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
    "  (lambda (f)"
    "    (format \"%s|%dx%d|%s\""
    "      (frame-parameter f 'name)"
    "      (frame-width f)"
    "      (frame-height f)"
    "      (if (eq f (selected-frame)) \"selected\" \"other\")))"
    "  (frame-list) \"\\n\")",
    &error);

  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── split_window ─────────────────────────────────────────────────── */

static McpToolResult *
handle_split_window (McpServer   *server,
                     const gchar *name,
                     JsonObject  *arguments,
                     gpointer     user_data)
{
  const gchar *direction;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  direction = json_object_get_string_member (arguments, "direction");
  if (direction != NULL && g_strcmp0 (direction, "horizontal") == 0)
    expr = g_strdup ("(split-window nil nil 'right)");
  else
    expr = g_strdup ("(split-window nil nil 'below)");

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── delete_window ────────────────────────────────────────────────── */

static McpToolResult *
handle_delete_window (McpServer   *server,
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

  result_str = cmacs_dispatch_eval ("(delete-window) t", &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── select_window ────────────────────────────────────────────────── */

static McpToolResult *
handle_select_window (McpServer   *server,
                      const gchar *name,
                      JsonObject  *arguments,
                      gpointer     user_data)
{
  const gchar *direction;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  direction = json_object_get_string_member (arguments, "direction");
  if (direction == NULL)
    expr = g_strdup ("(other-window 1) (buffer-name)");
  else if (g_strcmp0 (direction, "up") == 0)
    expr = g_strdup ("(windmove-up) (buffer-name)");
  else if (g_strcmp0 (direction, "down") == 0)
    expr = g_strdup ("(windmove-down) (buffer-name)");
  else if (g_strcmp0 (direction, "left") == 0)
    expr = g_strdup ("(windmove-left) (buffer-name)");
  else if (g_strcmp0 (direction, "right") == 0)
    expr = g_strdup ("(windmove-right) (buffer-name)");
  else
    expr = g_strdup ("(other-window 1) (buffer-name)");

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_window_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* list_windows */
  tool = mcp_tool_new ("list_windows",
    "List all windows with buffer, point, dimensions, and position.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_windows, NULL, NULL);
  g_object_unref (tool);

  /* list_frames */
  tool = mcp_tool_new ("list_frames",
    "List all frames with name, dimensions, and selection status.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_frames, NULL, NULL);
  g_object_unref (tool);

  /* split_window */
  tool = mcp_tool_new ("split_window",
    "Split the current window vertically or horizontally.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"direction\":{\"type\":\"string\","
    "\"enum\":[\"vertical\",\"horizontal\"],"
    "\"description\":\"Split direction (default: vertical)\"}}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_split_window, NULL, NULL);
  g_object_unref (tool);

  /* delete_window */
  tool = mcp_tool_new ("delete_window",
    "Delete (close) the currently selected window.");
  mcp_tool_set_destructive_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_delete_window, NULL, NULL);
  g_object_unref (tool);

  /* select_window */
  tool = mcp_tool_new ("select_window",
    "Select another window by direction (up/down/left/right) or cycle.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"direction\":{\"type\":\"string\","
    "\"enum\":[\"up\",\"down\",\"left\",\"right\"],"
    "\"description\":\"Direction to move (omit to cycle)\"}}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_select_window, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
