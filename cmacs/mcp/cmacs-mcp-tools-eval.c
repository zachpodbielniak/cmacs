/*
 * cmacs-mcp-tools-eval.c — Elisp evaluation and introspection tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
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

  expression = json_object_get_string_member (arguments, "expression");
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

/* ── describe_function ────────────────────────────────────────────── */

static McpToolResult *
handle_describe_function (McpServer   *server,
                          const gchar *name,
                          JsonObject  *arguments,
                          gpointer     user_data)
{
  const gchar *symbol;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  symbol = json_object_get_string_member (arguments, "symbol");
  if (symbol == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: symbol");
      return result;
    }

  expr = g_strdup_printf (
    "(let ((sym '%s))"
    "  (if (fboundp sym)"
    "    (format \"%%s\\n\\nArgs: %%s\\n\\n%%s\""
    "      sym"
    "      (or (help-function-arglist sym t) \"()\")"
    "      (or (documentation sym t) \"No documentation.\"))"
    "    (format \"%%s is not a known function\" sym)))",
    symbol);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── describe_variable ────────────────────────────────────────────── */

static McpToolResult *
handle_describe_variable (McpServer   *server,
                          const gchar *name,
                          JsonObject  *arguments,
                          gpointer     user_data)
{
  const gchar *symbol;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  symbol = json_object_get_string_member (arguments, "symbol");
  if (symbol == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: symbol");
      return result;
    }

  expr = g_strdup_printf (
    "(let ((sym '%s))"
    "  (if (boundp sym)"
    "    (format \"%%s\\n\\nValue: %%S\\n\\n%%s\""
    "      sym"
    "      (symbol-value sym)"
    "      (or (documentation-property sym 'variable-documentation t)"
    "          \"No documentation.\"))"
    "    (format \"%%s is void\" sym)))",
    symbol);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── apropos ──────────────────────────────────────────────────────── */

static McpToolResult *
handle_apropos (McpServer   *server,
                const gchar *name,
                JsonObject  *arguments,
                gpointer     user_data)
{
  const gchar *pattern;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  pattern = json_object_get_string_member (arguments, "pattern");
  if (pattern == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: pattern");
      return result;
    }

  expr = g_strdup_printf (
    "(mapconcat #'symbol-name (apropos-internal \"%s\") \"\\n\")",
    pattern);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
  return result;
}

/* ── completions ──────────────────────────────────────────────────── */

static McpToolResult *
handle_completions (McpServer   *server,
                    const gchar *name,
                    JsonObject  *arguments,
                    gpointer     user_data)
{
  const gchar *prefix;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *result_str = NULL;
  McpToolResult *result;

  (void) server;
  (void) name;
  (void) user_data;

  prefix = json_object_get_string_member (arguments, "prefix");
  if (prefix == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        "Missing required argument: prefix");
      return result;
    }

  expr = g_strdup_printf (
    "(let ((comps (all-completions \"%s\" obarray)))"
    "  (mapconcat #'identity (seq-take comps 100) \"\\n\"))",
    prefix);

  result_str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (result_str == NULL);
  mcp_tool_result_add_text (result,
    result_str ? result_str : error->message);
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

  /* describe_function */
  tool = mcp_tool_new ("describe_function",
    "Describe an Emacs Lisp function: arglist, docstring, and source location.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"symbol\":{\"type\":\"string\","
    "\"description\":\"Function symbol name\"}"
    "},\"required\":[\"symbol\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_describe_function, NULL, NULL);
  g_object_unref (tool);

  /* describe_variable */
  tool = mcp_tool_new ("describe_variable",
    "Describe an Emacs Lisp variable: current value and docstring.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"symbol\":{\"type\":\"string\","
    "\"description\":\"Variable symbol name\"}"
    "},\"required\":[\"symbol\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_describe_variable, NULL, NULL);
  g_object_unref (tool);

  /* apropos */
  tool = mcp_tool_new ("apropos",
    "Search for Emacs symbols matching a pattern. Returns one symbol per line.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"pattern\":{\"type\":\"string\","
    "\"description\":\"Regexp pattern to match against symbol names\"}"
    "},\"required\":[\"pattern\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_apropos, NULL, NULL);
  g_object_unref (tool);

  /* completions */
  tool = mcp_tool_new ("completions",
    "Get completion candidates for a symbol name prefix. Returns up to 100 matches.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"prefix\":{\"type\":\"string\","
    "\"description\":\"Symbol name prefix to complete\"}"
    "},\"required\":[\"prefix\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_completions, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
