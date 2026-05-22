/*
 * cmacs-mcp-tools-shell.c — Shell, scripting and media MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes the cmacs runtime subsystems an agent reaches for: the bacon
 * shell, the crispy embedded C language, the podomation automation
 * engine, and GStreamer video.  Every tool is individually #ifdef-gated
 * on its subsystem, so this file compiles regardless of configure
 * flags; cmacs_mcp_tools_shell_register() only registers what is built.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#if defined(HAVE_CMACS_BACON) || defined(HAVE_CMACS_CRISPY) \
  || defined(HAVE_CMACS_PODOMATION) || defined(HAVE_CMACS_VIDEO)

/* Helper: build an error result with MESSAGE. */
static McpToolResult *
shell_error (const gchar *message)
{
  McpToolResult *result = mcp_tool_result_new (TRUE);
  mcp_tool_result_add_text (result, message);
  return result;
}

/* Helper: dispatch EXPR, wrap printed result (or error) in a result. */
static McpToolResult *
shell_dispatch (const gchar *expr)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *str = cmacs_dispatch_eval (expr, &error);
  McpToolResult *result = mcp_tool_result_new (str == NULL);
  mcp_tool_result_add_text (result, str ? str : error->message);
  return result;
}

#endif

/* ── bacon_eval ───────────────────────────────────────────────────── */

#ifdef HAVE_CMACS_BACON
static McpToolResult *
handle_bacon_eval (McpServer *s, const gchar *n,
                   JsonObject *a, gpointer u)
{
  const gchar *command;
  g_autofree gchar *ec = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  command = json_object_get_string_member (a, "command");
  if (command == NULL)
    return shell_error ("Missing required argument: command");

  ec = g_strescape (command, NULL);
  expr = g_strdup_printf (
    "(let ((r (bacon-eval \"%s\")))"
    "  (format \"exit %%d\\n%%s\" (car r) (cdr r)))",
    ec);
  return shell_dispatch (expr);
}
#endif /* HAVE_CMACS_BACON */

/* ── crispy_eval ──────────────────────────────────────────────────── */

#ifdef HAVE_CMACS_CRISPY
static McpToolResult *
handle_crispy_eval (McpServer *s, const gchar *n,
                    JsonObject *a, gpointer u)
{
  const gchar *code;
  g_autofree gchar *ec = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  code = json_object_get_string_member (a, "code");
  if (code == NULL)
    return shell_error ("Missing required argument: code");

  ec = g_strescape (code, NULL);
  expr = g_strdup_printf (
    "(format \"crispy exit code: %%d\" (crispy-eval \"%s\"))", ec);
  return shell_dispatch (expr);
}
#endif /* HAVE_CMACS_CRISPY */

/* ── podomation tools ─────────────────────────────────────────────── */

#ifdef HAVE_CMACS_PODOMATION
/* Build an elisp alist literal from a JSON object of string values.
   Non-string members are skipped.  Returns "nil" for a NULL/empty
   object.  Caller frees. */
static gchar *
podomation_data_alist (JsonObject *data)
{
  GList *members, *m;
  GString *s;

  if (data == NULL)
    return g_strdup ("nil");
  members = json_object_get_members (data);
  if (members == NULL)
    return g_strdup ("nil");

  s = g_string_new ("(list");
  for (m = members; m != NULL; m = m->next)
    {
      const gchar *key = m->data;
      const gchar *val = json_object_get_string_member_with_default (
        data, key, NULL);
      g_autofree gchar *ek = NULL, *ev = NULL;
      if (val == NULL)
        continue;
      ek = g_strescape (key, NULL);
      ev = g_strescape (val, NULL);
      g_string_append_printf (s, " (cons \"%s\" \"%s\")", ek, ev);
    }
  g_list_free (members);
  g_string_append_c (s, ')');
  return g_string_free (s, FALSE);
}

static McpToolResult *
handle_podomation_emit_event (McpServer *s, const gchar *n,
                              JsonObject *a, gpointer u)
{
  const gchar *event;
  g_autofree gchar *ee = NULL, *data = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  event = json_object_get_string_member (a, "event");
  if (event == NULL)
    return shell_error ("Missing required argument: event");

  ee = g_strescape (event, NULL);
  data = podomation_data_alist (
    json_object_has_member (a, "data")
      ? json_object_get_object_member (a, "data") : NULL);
  expr = g_strdup_printf (
    "(progn (cmacs-podomation-emit-event \"%s\" %s)"
    "       (format \"emitted %%s\" \"%s\"))",
    ee, data, ee);
  return shell_dispatch (expr);
}

static McpToolResult *
handle_podomation_list_pods (McpServer *s, const gchar *n,
                             JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return shell_dispatch (
    "(prin1-to-string (cmacs-podomation-list-pods))");
}

static McpToolResult *
handle_podomation_eval_dsl (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  const gchar *dsl;
  g_autofree gchar *ed = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  dsl = json_object_get_string_member (a, "dsl");
  if (dsl == NULL)
    return shell_error ("Missing required argument: dsl");

  ed = g_strescape (dsl, NULL);
  expr = g_strdup_printf (
    "(progn (cmacs-podomation-eval-dsl \"%s\") \"DSL evaluated\")", ed);
  return shell_dispatch (expr);
}
#endif /* HAVE_CMACS_PODOMATION */

/* ── video tools ──────────────────────────────────────────────────── */

#ifdef HAVE_CMACS_VIDEO
static McpToolResult *
handle_video_list (McpServer *s, const gchar *n,
                   JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return shell_dispatch ("(prin1-to-string (cmacs-video-list))");
}

static McpToolResult *
handle_video_snapshot (McpServer *s, const gchar *n,
                       JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *path = NULL, *expr = NULL, *str = NULL;
  gint64 handle;
  McpToolResult *result;

  (void) s; (void) n; (void) u;

  if (!json_object_has_member (a, "handle"))
    return shell_error ("Missing required argument: handle");
  handle = json_object_get_int_member (a, "handle");

  path = g_strdup_printf ("%s/cmacs-mcp-video-%u.png",
                          g_get_tmp_dir (), g_random_int ());
  expr = g_strdup_printf (
    "(cmacs-video-snapshot-to-file %ld \"%s\")",
    (long) handle, path);

  str = cmacs_dispatch_eval (expr, &error);
  if (str == NULL)
    return shell_error (error->message);

  result = mcp_tool_result_new (FALSE);
  if (!cmacs_mcp_result_add_png_file (result, path))
    {
      mcp_tool_result_unref (result);
      return shell_error (
        "No frame available yet for that video handle");
    }
  return result;
}
#endif /* HAVE_CMACS_VIDEO */

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_shell_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  (void) server;
  (void) tool;
  (void) schema;

#ifdef HAVE_CMACS_BACON
  tool = mcp_tool_new ("bacon_eval",
    "Run a command in the embedded bacon shell. Returns the exit "
    "code and captured stdout/stderr.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"command\":{\"type\":\"string\","
      "\"description\":\"Shell command line to execute\"}"
    "},\"required\":[\"command\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_bacon_eval, NULL, NULL);
  g_object_unref (tool);
#endif

#ifdef HAVE_CMACS_CRISPY
  tool = mcp_tool_new ("crispy_eval",
    "Compile and run an inline crispy C code snippet. Returns the "
    "exit code.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"code\":{\"type\":\"string\","
      "\"description\":\"crispy C source to compile and execute\"}"
    "},\"required\":[\"code\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_crispy_eval, NULL, NULL);
  g_object_unref (tool);
#endif

#ifdef HAVE_CMACS_PODOMATION
  tool = mcp_tool_new ("podomation_emit_event",
    "Emit an event into the podomation automation engine, optionally "
    "with a data object of string values.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"event\":{\"type\":\"string\","
      "\"description\":\"Event name, e.g. on_buffer_save\"},"
    "\"data\":{\"type\":\"object\","
      "\"description\":\"Event payload (string values)\"}"
    "},\"required\":[\"event\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_podomation_emit_event,
                       NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("podomation_list_pods",
    "List active podomation pods and their health status.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_podomation_list_pods,
                       NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("podomation_eval_dsl",
    "Parse and execute a podomation DSL source string.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"dsl\":{\"type\":\"string\","
      "\"description\":\"podomation DSL source text\"}"
    "},\"required\":[\"dsl\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_podomation_eval_dsl,
                       NULL, NULL);
  g_object_unref (tool);
#endif

#ifdef HAVE_CMACS_VIDEO
  tool = mcp_tool_new ("video_list",
    "List all live cmacs-video stream handles.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_video_list, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("video_snapshot",
    "Capture the current frame of a video stream and return it as a "
    "PNG image.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\","
      "\"description\":\"Video stream handle from video_list\"}"
    "},\"required\":[\"handle\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_video_snapshot, NULL, NULL);
  g_object_unref (tool);
#endif
}

#endif /* HAVE_CMACS_MCP */
