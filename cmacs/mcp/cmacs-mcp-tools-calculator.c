/*
 * cmacs-mcp-tools-calculator.c — MCP tools for the cmacs-calculator subsystem
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes the calculator as MCP tools so external agents can compute
 * against a live cmacs:
 *   - calc_eval:             evaluate an expression numerically
 *   - calc_eval_symbolic:    evaluate symbolically (CAS: deriv/integ/solve)
 *   - calc_convert_units:    convert between units, or to base SI
 *   - calc_list:             enumerate the registered calculators
 *   - calc_describe:         describe one calculator
 *
 * D-Bus parity: org.cmacs.Editor1.Calc in
 * cmacs/dbus/cmacs-dbus-iface-calculator.c (sync discipline: adding a
 * tool here requires a matching method there, and vice versa).
 *
 * All handlers route through the Elisp dispatch path, so they run the
 * same engine -- and therefore the same corrected precedence, radian
 * angle mode and strict validation -- as M-x and the sheet buffer.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP
#ifdef HAVE_CMACS_CALCULATOR

#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <mcp.h>
#include <glib.h>
#include <string.h>

/* Escape a string for interpolation into a quoted Lisp string.  Every
 * expression here is untrusted input from an external agent, so this is the
 * boundary that keeps it data instead of code: without it a `"' in the
 * argument would close the string and the rest would be read as Lisp. */
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

/* Run EXPR through the Elisp dispatcher and wrap the reply as a tool
 * result.  ERRLABEL names the tool in the failure message. */
static McpToolResult *
eval_to_result (const gchar *expr, const gchar *errlabel)
{
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);

  mcp_tool_result_add_text (r, res ? res
                            : (err ? err->message : errlabel));
  return r;
}

/* Fetch a required string argument, or NULL. */
static const gchar *
arg_string (JsonObject *arguments, const gchar *key)
{
  return json_object_has_member (arguments, key)
    ? json_object_get_string_member (arguments, key) : NULL;
}

static McpToolResult *
handle_calc_eval (McpServer *server, const gchar *name,
                  JsonObject *arguments, gpointer user_data)
{
  const gchar *expr = arg_string (arguments, "expression");
  g_autofree gchar *expr_esc = NULL;
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (expr == NULL || *expr == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "calc_eval: missing 'expression'");
      return r;
    }

  expr_esc = escape_for_lisp (expr);
  /* The calculator signals on bad input rather than returning it
     unevaluated, so catch and report instead of failing the tool call. */
  lisp = g_strdup_printf (
    "(progn (require 'cmacs-calculator)"
    " (condition-case e (cmacs-calculator-eval \"%s\")"
    "  (error (format \"error: %%s\" (error-message-string e)))))",
    expr_esc);
  return eval_to_result (lisp, "calc_eval failed");
}

static McpToolResult *
handle_calc_eval_symbolic (McpServer *server, const gchar *name,
                           JsonObject *arguments, gpointer user_data)
{
  const gchar *expr = arg_string (arguments, "expression");
  g_autofree gchar *expr_esc = NULL;
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (expr == NULL || *expr == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "calc_eval_symbolic: missing 'expression'");
      return r;
    }

  expr_esc = escape_for_lisp (expr);
  lisp = g_strdup_printf (
    "(progn (require 'cmacs-calculator)"
    " (condition-case e (cmacs-calculator-eval-symbolic \"%s\")"
    "  (error (format \"error: %%s\" (error-message-string e)))))",
    expr_esc);
  return eval_to_result (lisp, "calc_eval_symbolic failed");
}

static McpToolResult *
handle_calc_convert_units (McpServer *server, const gchar *name,
                           JsonObject *arguments, gpointer user_data)
{
  const gchar *expr = arg_string (arguments, "expression");
  const gchar *units = arg_string (arguments, "units");
  g_autofree gchar *expr_esc = NULL;
  g_autofree gchar *units_esc = NULL;
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (expr == NULL || *expr == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "calc_convert_units: missing 'expression'");
      return r;
    }

  expr_esc = escape_for_lisp (expr);
  /* No target units means "reduce to base SI". */
  if (units == NULL || *units == '\0')
    lisp = g_strdup_printf (
      "(progn (require 'cmacs-calculator)"
      " (condition-case e (cmacs-calculator-to-base-units \"%s\")"
      "  (error (format \"error: %%s\" (error-message-string e)))))",
      expr_esc);
  else
    {
      units_esc = escape_for_lisp (units);
      lisp = g_strdup_printf (
        "(progn (require 'cmacs-calculator)"
        " (condition-case e (cmacs-calculator-convert-units \"%s\" \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        expr_esc, units_esc);
    }
  return eval_to_result (lisp, "calc_convert_units failed");
}

static McpToolResult *
handle_calc_list (McpServer *server, const gchar *name,
                  JsonObject *arguments, gpointer user_data)
{
  const gchar *category = arg_string (arguments, "category");
  g_autofree gchar *lisp = NULL;
  g_autofree gchar *cat_arg = NULL;

  (void) server; (void) name; (void) user_data;

  /* A category is a bare symbol in the call, so allow only names that
     cannot alter the form being built. */
  if (category != NULL && *category != '\0'
      && g_regex_match_simple ("^[a-z][a-z0-9-]*$", category, 0, 0))
    cat_arg = g_strdup_printf ("'%s", category);
  else
    cat_arg = g_strdup ("nil");

  lisp = g_strdup_printf (
    "(progn (require 'cmacs-calculator)"
    " (mapconcat (lambda (c) (format \"%%s (%%s) -- %%s\""
    "   (plist-get c :name) (plist-get c :category)"
    "   (or (plist-get c :title) \"\")))"
    "  (cmacs-calculator-list %s) \"\\n\"))",
    cat_arg);
  return eval_to_result (lisp, "calc_list failed");
}

static McpToolResult *
handle_calc_describe (McpServer *server, const gchar *name,
                      JsonObject *arguments, gpointer user_data)
{
  const gchar *calc = arg_string (arguments, "name");
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (calc == NULL || *calc == '\0'
      || !g_regex_match_simple ("^[a-z][a-z0-9-]*$", calc, 0, 0))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text
        (r, "calc_describe: 'name' must be a calculator name"
            " ([a-z][a-z0-9-]*)");
      return r;
    }

  lisp = g_strdup_printf (
    "(progn (require 'cmacs-calculator)"
    " (let ((c (cmacs-calculator-get '%s)))"
    "  (if (null c) \"error: no such calculator\""
    "   (format \"%%s -- %%s\\ncategory: %%s\\nargs: %%S\\nreturns: %%s\\n%%s\""
    "    (plist-get c :name) (or (plist-get c :title) \"\")"
    "    (plist-get c :category) (plist-get c :args)"
    "    (or (plist-get c :returns) \"\") (or (plist-get c :doc) \"\")))))",
    calc);
  return eval_to_result (lisp, "calc_describe failed");
}

void
cmacs_mcp_tools_calculator_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("calc_eval",
    "Evaluate a calculator EXPRESSION numerically and return the result.  "
    "Uses desktop-calculator semantics: '/' and '*' associate left to "
    "right (so 2/3*4 is 2.667), angles are radians, and symbolic "
    "constants fold (e^(i*pi) is -1).  Arbitrary precision.  All "
    "registered calculators are callable as functions, e.g. "
    "'bscall(100,100,0.05,0.2,1)' or 'lorentz(0.9)'.  Bad input is "
    "reported as an error rather than echoed back unevaluated.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"expression\":{\"type\":\"string\",\"description\":"
    "\"Expression, e.g. sqrt(5/3*3^4)\"}"
    "},\"required\":[\"expression\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_calc_eval, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("calc_eval_symbolic",
    "Evaluate a calculator EXPRESSION symbolically, permitting free "
    "variables.  This is the computer-algebra path: deriv(x^3,x), "
    "integ(x^2,x), solve(x^2-4=0,x), taylor(sin(x),x,5), factor, "
    "expand.  Use calc_eval instead when a number is wanted.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"expression\":{\"type\":\"string\",\"description\":"
    "\"Expression, e.g. deriv(x^3 + sin(x), x)\"}"
    "},\"required\":[\"expression\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_calc_eval_symbolic, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("calc_convert_units",
    "Evaluate EXPRESSION and convert it to UNITS; with no UNITS, reduce "
    "it to base SI.  Knows CODATA physical constants (c, G, h, hbar, k, "
    "Nav, me, mp), so '2 * G * 1.989e30 kg / c^2' reduces to the "
    "Schwarzschild radius of the Sun in metres, and '60 mph' converts to "
    "'m/s'.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"expression\":{\"type\":\"string\",\"description\":"
    "\"Expression with units, e.g. 60 mph\"},"
    "\"units\":{\"type\":\"string\",\"description\":"
    "\"Target units, e.g. m/s; omit to reduce to base SI\"}"
    "},\"required\":[\"expression\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_calc_convert_units, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("calc_list",
    "List the registered calculators, optionally only those in one "
    "CATEGORY (financial, physics, relativity, tax, ...).  Each is "
    "callable as a function from calc_eval.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"category\":{\"type\":\"string\",\"description\":"
    "\"Category to filter by\"}"
    "},\"required\":[]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_calc_list, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("calc_describe",
    "Describe one calculator by NAME: its title, category, arguments, "
    "return value and documentation.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\",\"description\":"
    "\"Calculator name, e.g. bscall\"}"
    "},\"required\":[\"name\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_calc_describe, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_CALCULATOR */
#endif /* HAVE_CMACS_MCP */
