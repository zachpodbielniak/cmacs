/*
 * cmacs-mcp-tools-cintrospect.c — MCP tools for runtime C introspection
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Re-exports the cintrospect Lisp DEFUNs as MCP tools so an LLM
 * client can drive C-level introspection (and, when cpatch is built,
 * hot-patching) over the wire.
 *
 * Pattern mirrors cmacs-mcp-tools-debug.c: each tool's handler
 * formats a Lisp expression and dispatches via cmacs_dispatch_eval,
 * returning the printed result as a text resource.
 *
 * Built only when both HAVE_CMACS_MCP and HAVE_CMACS_CINTROSPECT.
 */

#include <config.h>

#if defined (HAVE_CMACS_MCP) && defined (HAVE_CMACS_CINTROSPECT)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <string.h>

/* ── Helpers ──────────────────────────────────────────────────────── */

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

/* Defensive: pull a string from arg JSON, escape it for Elisp. */
static gchar *
arg_string (JsonObject *args, const gchar *key)
{
  if (args == NULL || !json_object_has_member (args, key))
    return NULL;
  const gchar *raw = json_object_get_string_member (args, key);
  if (raw == NULL)
    return NULL;
  /* Escape backslashes and double-quotes for embedding in an Elisp
   * string literal.  We deliberately do not implement full quoting
   * (no control chars expected from MCP clients in symbol names). */
  GString *s = g_string_new (NULL);
  for (const gchar *p = raw; *p; p++)
    {
      if (*p == '\\' || *p == '"')
        g_string_append_c (s, '\\');
      g_string_append_c (s, *p);
    }
  return g_string_free (s, FALSE);
}

static gint64
arg_int (JsonObject *args, const gchar *key, gint64 dflt)
{
  if (args == NULL || !json_object_has_member (args, key))
    return dflt;
  return json_object_get_int_member (args, key);
}

/* ── Read-only tools (Tier 0) ────────────────────────────────────── */

static McpToolResult *
handle_list (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  g_autofree gchar *kind = arg_string (args, "kind");
  g_autofree gchar *glob = arg_string (args, "glob");
  gint64 limit = arg_int (args, "limit", -1);
  if (kind == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "missing required arg: kind");
      return r;
    }
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-list (quote %s) %s%s%s %s))",
    kind,
    glob ? "\"" : "",
    glob ? glob : "nil",
    glob ? "\"" : "",
    limit >= 0 ? g_strdup_printf ("%ld", (long) limit) : g_strdup ("nil"));
  return eval_tool (expr);
}

static McpToolResult *
handle_symbol_info (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  g_autofree gchar *name = arg_string (args, "name");
  if (name == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "missing required arg: name");
      return r;
    }
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-symbol-info \"%s\"))", name);
  return eval_tool (expr);
}

static McpToolResult *
handle_type_info (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  g_autofree gchar *name = arg_string (args, "name");
  if (name == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "missing required arg: name");
      return r;
    }
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-type-info \"%s\"))", name);
  return eval_tool (expr);
}

static McpToolResult *
handle_function_source (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  g_autofree gchar *name = arg_string (args, "name");
  if (name == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "missing required arg: name");
      return r;
    }
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-function-source \"%s\"))", name);
  return eval_tool (expr);
}

static McpToolResult *
handle_addr_to_source (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  if (!json_object_has_member (args, "addr"))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "missing required arg: addr (integer)");
      return r;
    }
  gint64 addr = json_object_get_int_member (args, "addr");
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-addr-to-source %ld))", (long) addr);
  return eval_tool (expr);
}

static McpToolResult *
handle_defun_info (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  g_autofree gchar *sym = arg_string (args, "symbol");
  if (sym == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "missing required arg: symbol");
      return r;
    }
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-defun-info (intern \"%s\")))", sym);
  return eval_tool (expr);
}

static McpToolResult *
handle_stack_trace (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  gint64 depth = arg_int (args, "depth", 32);
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-stack-trace %ld))", (long) depth);
  return eval_tool (expr);
}

/* ── Tier 1 (JIT) tools — Phase 2 stubs return the not-impl error ── */

static McpToolResult *
handle_compile_snippet (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) args; (void) u;
  return eval_tool (
    "(condition-case err"
    " (cmacs-c-compile \"\" \"x\" nil)"
    " (cmacs-cintrospect-not-implemented (cadr err))"
    " (error (format \"%S\" err)))");
}

static McpToolResult *
handle_call_handle (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) args; (void) u;
  return eval_tool (
    "(condition-case err"
    " (cmacs-c-call nil)"
    " (cmacs-cintrospect-not-implemented (cadr err))"
    " (error (format \"%S\" err)))");
}

/* ── cpatch tools (gated by both build flag and runtime defcustom) ── */

#ifdef HAVE_CMACS_CPATCH

static McpToolResult *
patching_gate_check (void)
{
  /* Refuse if the user hasn't opted in. */
  g_autoptr (GError) error = NULL;
  g_autofree gchar *r = cmacs_dispatch_eval (
    "(if (and (boundp 'cmacs-mcp-cintrospect-enable-patching)"
    "         cmacs-mcp-cintrospect-enable-patching)"
    "    \"ok\""
    "  \"BLOCKED: set `cmacs-mcp-cintrospect-enable-patching' to t to allow MCP-driven hot-patching\")",
    &error);
  if (r != NULL && strncmp (r, "\"ok\"", 4) == 0)
    return NULL;
  McpToolResult *result = mcp_tool_result_new (TRUE);
  mcp_tool_result_add_text (result, r ? r : error->message);
  return result;
}

static McpToolResult *
handle_patch_defun (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  McpToolResult *gate = patching_gate_check ();
  if (gate != NULL) return gate;
  g_autofree gchar *sym = arg_string (args, "symbol");
  if (sym == NULL || !json_object_has_member (args, "addr"))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "required: symbol (string) + addr (integer)");
      return r;
    }
  gint64 addr = json_object_get_int_member (args, "addr");
  g_autofree gchar *expr = g_strdup_printf (
    "(condition-case err"
    " (progn (cmacs-c-patch-defun (intern \"%s\") %ld) \"ok\")"
    " (error (format \"%%S\" err)))",
    sym, (long) addr);
  return eval_tool (expr);
}

static McpToolResult *
handle_unpatch_defun (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) u;
  McpToolResult *gate = patching_gate_check ();
  if (gate != NULL) return gate;
  g_autofree gchar *sym = arg_string (args, "symbol");
  if (sym == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "required: symbol (string)");
      return r;
    }
  g_autofree gchar *expr = g_strdup_printf (
    "(prin1-to-string (cmacs-c-unpatch-defun (intern \"%s\")))", sym);
  return eval_tool (expr);
}

static McpToolResult *
handle_patch_log (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) args; (void) u;
  return eval_tool (
    "(prin1-to-string (cmacs-c-patch-list))");
}

static McpToolResult *
handle_unpatch_all (McpServer *s, const gchar *n, JsonObject *args, gpointer u)
{
  (void) s; (void) n; (void) args; (void) u;
  /* unpatch-all is intentionally NOT gated --- it's the panic button. */
  return eval_tool (
    "(format \"unpatched %d\" (cmacs-c-unpatch-all))");
}

#endif /* HAVE_CMACS_CPATCH */

/* ── Master registration ──────────────────────────────────────────── */

void
cmacs_mcp_tools_cintrospect_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* cmacs.c.list */
  tool = mcp_tool_new ("cmacs.c.list",
    "List C-level entities of KIND (symbol|defun|object), optionally "
    "filtered by GLOB.  Returns a list of plists.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"kind\":{\"type\":\"string\",\"enum\":[\"symbol\",\"defun\",\"object\"],"
    "  \"description\":\"Kind of entity to list\"},"
    "\"glob\":{\"type\":\"string\",\"description\":\"Optional shell-glob filter\"},"
    "\"limit\":{\"type\":\"integer\",\"description\":\"Max rows (default unlimited)\"}"
    "},\"required\":[\"kind\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.symbol_info */
  tool = mcp_tool_new ("cmacs.c.symbol_info",
    "Return a plist describing the C symbol named NAME (file, line, "
    "addr, kind, object, size).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\",\"description\":\"C symbol name (e.g. Fbuffer_string)\"}"
    "},\"required\":[\"name\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_symbol_info, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.type_info */
  tool = mcp_tool_new ("cmacs.c.type_info",
    "Return a plist describing the C type NAME (struct/union/enum) "
    "with field offsets, sizes, and types.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\",\"description\":\"C type name (e.g. struct frame)\"}"
    "},\"required\":[\"name\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_type_info, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.function_source */
  tool = mcp_tool_new ("cmacs.c.function_source",
    "Return (file . line) for the C function NAME, or nil.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\"}"
    "},\"required\":[\"name\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_function_source, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.addr_to_source */
  tool = mcp_tool_new ("cmacs.c.addr_to_source",
    "Resolve a runtime address ADDR to (file line function).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"addr\":{\"type\":\"integer\"}"
    "},\"required\":[\"addr\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_addr_to_source, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.defun_info */
  tool = mcp_tool_new ("cmacs.c.defun_info",
    "Return a plist describing the DEFUN named SYMBOL (Lisp side).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"symbol\":{\"type\":\"string\",\"description\":\"Lisp symbol name (e.g. buffer-string)\"}"
    "},\"required\":[\"symbol\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_defun_info, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.stack_trace */
  tool = mcp_tool_new ("cmacs.c.stack_trace",
    "Return a list of frame plists describing the current C stack.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"depth\":{\"type\":\"integer\",\"description\":\"Max frames (default 32)\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_stack_trace, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.compile_snippet (Phase 2 stub) */
  tool = mcp_tool_new ("cmacs.c.compile_snippet",
    "Compile a C SOURCE string to a callable handle.  Phase 2 --- "
    "currently returns the cmacs-cintrospect-not-implemented sentinel.");
  mcp_server_add_tool (server, tool, handle_compile_snippet, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.call_handle (Phase 2 stub) */
  tool = mcp_tool_new ("cmacs.c.call_handle",
    "Call a JIT compilation HANDLE with ARGS.  Phase 2 stub.");
  mcp_server_add_tool (server, tool, handle_call_handle, NULL, NULL);
  g_object_unref (tool);

#ifdef HAVE_CMACS_CPATCH
  /* cmacs.c.patch_defun */
  tool = mcp_tool_new ("cmacs.c.patch_defun",
    "Hot-patch the DEFUN named SYMBOL to call the function at ADDR.  "
    "Gated on `cmacs-mcp-cintrospect-enable-patching' (default nil).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"symbol\":{\"type\":\"string\"},"
    "\"addr\":{\"type\":\"integer\"}"
    "},\"required\":[\"symbol\",\"addr\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_patch_defun, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.unpatch_defun */
  tool = mcp_tool_new ("cmacs.c.unpatch_defun",
    "Restore the original C function for the DEFUN named SYMBOL.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"symbol\":{\"type\":\"string\"}"
    "},\"required\":[\"symbol\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_unpatch_defun, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.patch_log */
  tool = mcp_tool_new ("cmacs.c.patch_log",
    "List currently-applied patches.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_patch_log, NULL, NULL);
  g_object_unref (tool);

  /* cmacs.c.unpatch_all */
  tool = mcp_tool_new ("cmacs.c.unpatch_all",
    "Panic button --- restore every patched DEFUN.  Returns the count.  "
    "NOT gated by enable-patching defcustom (you always want a panic out).");
  mcp_server_add_tool (server, tool, handle_unpatch_all, NULL, NULL);
  g_object_unref (tool);
#endif /* HAVE_CMACS_CPATCH */
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_CINTROSPECT */
