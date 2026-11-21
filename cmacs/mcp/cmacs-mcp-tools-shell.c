/*
 * cmacs-mcp-tools-shell.c — the shell, scripting and media MCP tools
 * that are still C
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Five tools, kept as hand-written handlers on purpose:
 *
 *   bacon_eval, crispy_eval, podomation_eval_dsl, podomation_repl_eval
 *       run code the caller supplies.  They are in the privileged set
 *       the brigade's allowlist names, and stay where a change to them
 *       is reviewed as a change to that set.
 *   video_snapshot
 *       returns a PNG; a registry tool returns text.
 *
 * Every tool is individually #ifdef-gated on its subsystem, so this
 * file compiles regardless of configure flags;
 * cmacs_mcp_tools_shell_register() only registers what is built.
 *
 * The other eight podomation_* tools and video_list that used to be
 * registered here are registry tools now (lisp/cmacs/
 * cmacs-podomation-tools.el, cmacs-video-tools.el), published by
 * cmacs-mcp-tools-brigade.c; their C handlers were deleted.  What they
 * promised a client is frozen in test/cmacs/data/mcp-wire-schema.json.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <glib/gstdio.h>

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

#endif

#if defined(HAVE_CMACS_BACON) || defined(HAVE_CMACS_CRISPY) \
  || defined(HAVE_CMACS_PODOMATION)

/* Helper: dispatch EXPR, wrap printed result (or error) in a result.
   Not for the video tool, which answers with an image: a build with
   video and none of the three above must not be left with an unused
   static function.  */
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

  command = json_object_get_string_member_with_default (a, "command", NULL);
  if (command == NULL)
    return shell_error ("Missing required argument: command");

  ec = cmacs_dispatch_lisp_escape (command);
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

  code = json_object_get_string_member_with_default (a, "code", NULL);
  if (code == NULL)
    return shell_error ("Missing required argument: code");

  ec = cmacs_dispatch_lisp_escape (code);
  expr = g_strdup_printf (
    "(format \"crispy exit code: %%d\" (crispy-eval \"%s\"))", ec);
  return shell_dispatch (expr);
}
#endif /* HAVE_CMACS_CRISPY */

/* ── podomation tools ─────────────────────────────────────────────── */

#ifdef HAVE_CMACS_PODOMATION
static McpToolResult *
handle_podomation_eval_dsl (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  const gchar *dsl;
  g_autofree gchar *ed = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  dsl = json_object_get_string_member_with_default (a, "dsl", NULL);
  if (dsl == NULL)
    return shell_error ("Missing required argument: dsl");

  ed = cmacs_dispatch_lisp_escape (dsl);
  expr = g_strdup_printf (
    "(progn (cmacs-podomation-eval-dsl \"%s\") \"DSL evaluated\")", ed);
  return shell_dispatch (expr);
}

static McpToolResult *
handle_podomation_repl_eval (McpServer *s, const gchar *n,
                             JsonObject *a, gpointer u)
{
  const gchar *line;
  g_autofree gchar *el = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  line = json_object_get_string_member_with_default (a, "line", NULL);
  if (line == NULL)
    return shell_error ("Missing required argument: line");

  el = cmacs_dispatch_lisp_escape (line);
  expr = g_strdup_printf (
    "(let ((r (cmacs-podomation-repl-eval \"%s\")))"
    "  (format \"%%s: %%s\" (car r) (or (cdr r) \"\")))",
    el);
  return shell_dispatch (expr);
}
#endif /* HAVE_CMACS_PODOMATION */

/* ── video tools ──────────────────────────────────────────────────── */

#ifdef HAVE_CMACS_VIDEO
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

  path = cmacs_mcp_temp_path ("cmacs-mcp-video-XXXXXX.png");
  if (path == NULL)
    return shell_error ("cannot create a scratch file for the snapshot");
  {
    g_autofree gchar *epath = cmacs_dispatch_lisp_escape (path);
    /* CMACS redact: a frame of a video playing in a buffer the user's
       privacy rules exclude is refused (the guard signals).  */
    expr = g_strdup_printf (
      "(progn (require 'cmacs-redact)"
      " (cmacs-redact-capture-guard 'video %" G_GINT64_FORMAT ")"
      " (cmacs-video-snapshot-to-file %ld \"%s\"))",
      handle, (long) handle, epath);
  }

  str = cmacs_dispatch_eval (expr, &error);
  if (str == NULL)
    {
      g_unlink (path);
      return shell_error (error->message);
    }

  result = mcp_tool_result_new (FALSE);
  if (!cmacs_mcp_result_add_png_file (result, path))
    {
      mcp_tool_result_unref (result);
      g_unlink (path);
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

  tool = mcp_tool_new ("podomation_repl_eval",
    "Evaluate one line of DSL input in the persistent podomation "
    "REPL. State (pods, variables) carries across calls, so this "
    "supports iterative authoring.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"line\":{\"type\":\"string\","
      "\"description\":\"A line of podomation DSL input\"}"
    "},\"required\":[\"line\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_podomation_repl_eval,
                       NULL, NULL);
  g_object_unref (tool);
#endif

#ifdef HAVE_CMACS_VIDEO
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
