/*
 * cmacs-mcp-tools-debug.c — Debugging and diagnostics MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <unistd.h>

/* Helper: eval and return result or error. */
static McpToolResult *
eval_tool (const gchar *expr)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *result_str = cmacs_dispatch_eval (expr, &error);
  McpToolResult *result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── backtrace ────────────────────────────────────────────────────── */

static McpToolResult *
handle_backtrace (McpServer   *server,
                  const gchar *name,
                  JsonObject  *arguments,
                  gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool (
    "(with-output-to-string (backtrace))");
}

/* ── memory_info ──────────────────────────────────────────────────── */

static McpToolResult *
handle_memory_info (McpServer   *server,
                    const gchar *name,
                    JsonObject  *arguments,
                    gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool (
    "(format \"GC stats: %S\\nMemory use counts: %S\""
    "  (garbage-collect) (memory-use-counts))");
}

/* ── process_status ───────────────────────────────────────────────── */

static McpToolResult *
handle_process_status (McpServer   *server,
                       const gchar *name,
                       JsonObject  *arguments,
                       gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool (
    "(format \"PID: %d\\nUptime: %s\\nEmacs version: %s\\n"
    "System: %s\\nFeatures: %d loaded\""
    "  (emacs-pid)"
    "  (emacs-uptime)"
    "  emacs-version"
    "  system-type"
    "  (length features))");
}

/* ── recent_messages ──────────────────────────────────────────────── */

static McpToolResult *
handle_recent_messages (McpServer   *server,
                        const gchar *name,
                        JsonObject  *arguments,
                        gpointer     user_data)
{
  gint64 lines = 50;

  (void) server;
  (void) name;
  (void) user_data;

  if (arguments != NULL && json_object_has_member (arguments, "lines"))
    lines = json_object_get_int_member (arguments, "lines");

  {
    g_autofree gchar *expr = g_strdup_printf (
      "(with-current-buffer \"*Messages*\""
      "  (let ((s (max (- (point-max) 1) (point-min))))"
      "    (save-excursion"
      "      (goto-char (point-max))"
      "      (forward-line -%ld)"
      "      (buffer-substring-no-properties (point) (point-max)))))",
      (long) lines);
    return eval_tool (expr);
  }
}

/* ── describe_mode ────────────────────────────────────────────────── */

static McpToolResult *
handle_describe_mode (McpServer   *server,
                      const gchar *name,
                      JsonObject  *arguments,
                      gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool (
    "(format \"Major mode: %s\\nMinor modes: %s\""
    "  (symbol-name major-mode)"
    "  (mapconcat #'symbol-name minor-mode-list \" \"))");
}

/* ── list_hooks ───────────────────────────────────────────────────── */

static McpToolResult *
handle_list_hooks (McpServer   *server,
                   const gchar *name,
                   JsonObject  *arguments,
                   gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool (
    "(let (hooks)"
    "  (mapatoms"
    "    (lambda (sym)"
    "      (when (and (boundp sym)"
    "                 (string-suffix-p \"-hook\" (symbol-name sym))"
    "                 (symbol-value sym))"
    "        (push (format \"%s: %S\" sym (symbol-value sym)) hooks))))"
    "  (mapconcat #'identity (sort hooks #'string<) \"\\n\"))");
}

/* ── profiler_start ───────────────────────────────────────────────── */

static McpToolResult *
handle_profiler_start (McpServer   *server,
                       const gchar *name,
                       JsonObject  *arguments,
                       gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool ("(profiler-start 'cpu) \"Profiler started\"");
}

/* ── profiler_stop ────────────────────────────────────────────────── */

static McpToolResult *
handle_profiler_stop (McpServer   *server,
                      const gchar *name,
                      JsonObject  *arguments,
                      gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool ("(profiler-stop) \"Profiler stopped\"");
}

/* ── profiler_report ──────────────────────────────────────────────── */

static McpToolResult *
handle_profiler_report (McpServer   *server,
                        const gchar *name,
                        JsonObject  *arguments,
                        gpointer     user_data)
{
  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;
  return eval_tool (
    "(with-temp-buffer"
    "  (profiler-report-cpu)"
    "  (buffer-substring-no-properties (point-min) (point-max)))");
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_debug_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("backtrace",
    "Get the current Lisp backtrace.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_backtrace, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("memory_info",
    "Get GC statistics and memory usage counts.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_memory_info, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("process_status",
    "Get Emacs process info: PID, uptime, version, system type.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_process_status, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("recent_messages",
    "Get recent entries from the *Messages* buffer.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"lines\":{\"type\":\"integer\","
    "\"description\":\"Number of lines to retrieve (default: 50)\"}}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_recent_messages, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("describe_mode",
    "Get the current major mode and active minor modes.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_describe_mode, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("list_hooks",
    "List all non-nil hook variables and their values.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_hooks, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("profiler_start",
    "Start the Emacs CPU profiler.");
  mcp_server_add_tool (server, tool, handle_profiler_start, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("profiler_stop",
    "Stop the Emacs CPU profiler.");
  mcp_server_add_tool (server, tool, handle_profiler_stop, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("profiler_report",
    "Get the CPU profiler report.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_profiler_report, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
