/*
 * cmacs-mcp-tools-buffer.c — Buffer management MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* ── list_buffers ─────────────────────────────────────────────────── */

static McpToolResult *
handle_list_buffers (McpServer   *server,
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
    "  (lambda (b)"
    "    (format \"%s|%s|%s|%s|%d\""
    "      (buffer-name b)"
    "      (or (buffer-file-name b) \"\")"
    "      (if (buffer-modified-p b) \"modified\" \"unmodified\")"
    "      (with-current-buffer b (symbol-name major-mode))"
    "      (buffer-size b)))"
    "  (buffer-list) \"\\n\")",
    &error);

  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── get_buffer_content ───────────────────────────────────────────── */

static McpToolResult *
handle_get_buffer_content (McpServer   *server,
                           const gchar *name,
                           JsonObject  *arguments,
                           gpointer     user_data)
{
  const gchar *buffer_name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;
  gint64 start = 0, end = 0;

  (void) server;
  (void) name;
  (void) user_data;

  buffer_name = json_object_get_string_member (arguments, "buffer");
  if (buffer_name == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: buffer");
      return result;
    }

  if (json_object_has_member (arguments, "start"))
    start = json_object_get_int_member (arguments, "start");
  if (json_object_has_member (arguments, "end"))
    end = json_object_get_int_member (arguments, "end");

  if (start > 0 && end > 0)
    expr = g_strdup_printf (
      "(with-current-buffer \"%s\""
      "  (buffer-substring-no-properties %ld %ld))",
      buffer_name, (long) start, (long) end);
  else
    expr = g_strdup_printf (
      "(with-current-buffer \"%s\""
      "  (buffer-substring-no-properties (point-min) (point-max)))",
      buffer_name);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── set_buffer_content ───────────────────────────────────────────── */

static McpToolResult *
handle_set_buffer_content (McpServer   *server,
                           const gchar *name,
                           JsonObject  *arguments,
                           gpointer     user_data)
{
  const gchar *buffer_name, *content;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  g_autofree gchar *escaped = NULL;
  McpToolResult *result;
  gint64 start = 0, end = 0;

  (void) server;
  (void) name;
  (void) user_data;

  buffer_name = json_object_get_string_member (arguments, "buffer");
  content = json_object_get_string_member (arguments, "content");
  if (buffer_name == NULL || content == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required arguments: buffer, content");
      return result;
    }

  /* Escape content for embedding in an Elisp string literal. */
  escaped = g_strescape (content, NULL);

  if (json_object_has_member (arguments, "start"))
    start = json_object_get_int_member (arguments, "start");
  if (json_object_has_member (arguments, "end"))
    end = json_object_get_int_member (arguments, "end");

  if (start > 0 && end > 0)
    expr = g_strdup_printf (
      "(with-current-buffer \"%s\""
      "  (delete-region %ld %ld)"
      "  (goto-char %ld)"
      "  (insert \"%s\")"
      "  t)",
      buffer_name, (long) start, (long) end, (long) start, escaped);
  else
    expr = g_strdup_printf (
      "(with-current-buffer \"%s\""
      "  (erase-buffer)"
      "  (insert \"%s\")"
      "  t)",
      buffer_name, escaped);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── create_buffer ────────────────────────────────────────────────── */

static McpToolResult *
handle_create_buffer (McpServer   *server,
                      const gchar *name,
                      JsonObject  *arguments,
                      gpointer     user_data)
{
  const gchar *buffer_name, *content;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  buffer_name = json_object_get_string_member (arguments, "name");
  if (buffer_name == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: name");
      return result;
    }

  content = json_object_get_string_member (arguments, "content");
  if (content != NULL)
    {
      g_autofree gchar *escaped = g_strescape (content, NULL);
      expr = g_strdup_printf (
        "(with-current-buffer (get-buffer-create \"%s\")"
        "  (insert \"%s\")"
        "  (buffer-name))",
        buffer_name, escaped);
    }
  else
    expr = g_strdup_printf (
      "(buffer-name (get-buffer-create \"%s\"))",
      buffer_name);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── kill_buffer ──────────────────────────────────────────────────── */

static McpToolResult *
handle_kill_buffer (McpServer   *server,
                    const gchar *name,
                    JsonObject  *arguments,
                    gpointer     user_data)
{
  const gchar *buffer_name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  buffer_name = json_object_get_string_member (arguments, "buffer");
  if (buffer_name == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: buffer");
      return result;
    }

  expr = g_strdup_printf ("(kill-buffer \"%s\")", buffer_name);
  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── switch_to_buffer ─────────────────────────────────────────────── */

static McpToolResult *
handle_switch_to_buffer (McpServer   *server,
                         const gchar *name,
                         JsonObject  *arguments,
                         gpointer     user_data)
{
  const gchar *buffer_name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  buffer_name = json_object_get_string_member (arguments, "buffer");
  if (buffer_name == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: buffer");
      return result;
    }

  expr = g_strdup_printf (
    "(buffer-name (switch-to-buffer \"%s\"))", buffer_name);
  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── save_buffer ──────────────────────────────────────────────────── */

static McpToolResult *
handle_save_buffer (McpServer   *server,
                    const gchar *name,
                    JsonObject  *arguments,
                    gpointer     user_data)
{
  const gchar *buffer_name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  buffer_name = json_object_get_string_member (arguments, "buffer");
  if (buffer_name == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: buffer");
      return result;
    }

  expr = g_strdup_printf (
    "(with-current-buffer \"%s\" (save-buffer) t)", buffer_name);
  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── find_file ────────────────────────────────────────────────────── */

static McpToolResult *
handle_find_file (McpServer   *server,
                  const gchar *name,
                  JsonObject  *arguments,
                  gpointer     user_data)
{
  const gchar *path;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  path = json_object_get_string_member (arguments, "path");
  if (path == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: path");
      return result;
    }

  cmacs_dispatch_find_file (path);
  result = mcp_tool_result_new (FALSE);
  mcp_tool_result_add_text (result, path);
  return result;
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_buffer_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* list_buffers */
  tool = mcp_tool_new ("list_buffers",
    "List all buffers with name, file, modified status, major-mode, and size. "
    "Returns pipe-separated fields, one buffer per line.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_buffers, NULL, NULL);
  g_object_unref (tool);

  /* get_buffer_content */
  tool = mcp_tool_new ("get_buffer_content",
    "Read the text content of a buffer. Optionally specify start/end positions.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"start\":{\"type\":\"integer\",\"description\":\"Start position (1-based)\"},"
    "\"end\":{\"type\":\"integer\",\"description\":\"End position (1-based)\"}"
    "},\"required\":[\"buffer\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_get_buffer_content, NULL, NULL);
  g_object_unref (tool);

  /* set_buffer_content */
  tool = mcp_tool_new ("set_buffer_content",
    "Replace text in a buffer. If start/end given, replaces that range; "
    "otherwise replaces entire buffer content.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"content\":{\"type\":\"string\",\"description\":\"New text content\"},"
    "\"start\":{\"type\":\"integer\",\"description\":\"Start position (1-based)\"},"
    "\"end\":{\"type\":\"integer\",\"description\":\"End position (1-based)\"}"
    "},\"required\":[\"buffer\",\"content\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_destructive_hint (tool, FALSE);
  mcp_server_add_tool (server, tool, handle_set_buffer_content, NULL, NULL);
  g_object_unref (tool);

  /* create_buffer */
  tool = mcp_tool_new ("create_buffer",
    "Create a new buffer with an optional initial content.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"content\":{\"type\":\"string\",\"description\":\"Initial content\"}"
    "},\"required\":[\"name\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_create_buffer, NULL, NULL);
  g_object_unref (tool);

  /* kill_buffer */
  tool = mcp_tool_new ("kill_buffer",
    "Kill (close) a buffer.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"}"
    "},\"required\":[\"buffer\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_destructive_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_kill_buffer, NULL, NULL);
  g_object_unref (tool);

  /* switch_to_buffer */
  tool = mcp_tool_new ("switch_to_buffer",
    "Switch the current window to display a buffer.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"}"
    "},\"required\":[\"buffer\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_switch_to_buffer, NULL, NULL);
  g_object_unref (tool);

  /* save_buffer */
  tool = mcp_tool_new ("save_buffer",
    "Save a buffer to its associated file.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"}"
    "},\"required\":[\"buffer\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_save_buffer, NULL, NULL);
  g_object_unref (tool);

  /* find_file */
  tool = mcp_tool_new ("find_file",
    "Open a file in Emacs (equivalent to C-x C-f / find-file).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"path\":{\"type\":\"string\",\"description\":\"File path to open\"}"
    "},\"required\":[\"path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_find_file, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
