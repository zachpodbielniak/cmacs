/*
 * cmacs-mcp-tools-gsurf.c — gsurf embedded web browser MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes the gsurf browser to MCP clients (and, via the MCP->ai
 * bridge, to cmacs-ai).  Each tool builds an Elisp expression calling
 * the cmacs-gsurf-mcp-* helpers in lisp/cmacs/cmacs-gsurf.el and runs
 * it through the safe eval dispatcher, so the buffer-resolution logic
 * lives in one place (Elisp) and this layer stays a thin bridge.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_GSURF)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Wrap a dispatched-eval result string into an McpToolResult. */
static McpToolResult *
gsurf_eval (const gchar *expr)
{
  GError *error = NULL;
  gchar *str = cmacs_dispatch_eval (expr, &error);
  McpToolResult *result;
  if (str == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        error ? error->message : "gsurf error");
    }
  else
    {
      result = mcp_tool_result_new (FALSE);
      mcp_tool_result_add_text (result, str);
      g_free (str);
    }
  g_clear_error (&error);
  return result;
}

/* Build an Elisp string literal from a C string (escaping \ and ").
   Returns a newly-allocated string; never NULL. */
static gchar *
elisp_string (const gchar *s)
{
  if (s == NULL)
    return g_strdup ("\"\"");
  GString *out = g_string_new ("\"");
  for (const gchar *p = s; *p; p++)
    {
      if (*p == '\\' || *p == '"')
        g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  g_string_append_c (out, '"');
  return g_string_free (out, FALSE);
}

/* Optional "buffer" arg -> an Elisp string literal or "nil". */
static gchar *
buffer_arg (JsonObject *a)
{
  const gchar *b = a ? json_object_get_string_member_with_default (a, "buffer", NULL)
                     : NULL;
  return (b && *b) ? elisp_string (b) : g_strdup ("nil");
}

static McpToolResult *
missing_arg (const gchar *name)
{
  McpToolResult *r = mcp_tool_result_new (TRUE);
  g_autofree gchar *m = g_strdup_printf ("Missing required argument: %s", name);
  mcp_tool_result_add_text (r, m);
  return r;
}

/* ── Handlers ─────────────────────────────────────────────────────── */

static McpToolResult *
handle_gsurf_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *url = json_object_get_string_member_with_default (a, "url", NULL);
  if (url == NULL)
    return missing_arg ("url");
  g_autofree gchar *q = elisp_string (url);
  g_autofree gchar *expr = g_strdup_printf ("(cmacs-gsurf-mcp-open %s)", q);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_navigate (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *url = json_object_get_string_member_with_default (a, "url", NULL);
  if (url == NULL)
    return missing_arg ("url");
  g_autofree gchar *q = elisp_string (url);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-navigate %s %s)", q, buf);
  return gsurf_eval (expr);
}

/* Shared body for the no-payload, buffer-only navigation verbs. */
static McpToolResult *
gsurf_verb (JsonObject *a, const gchar *fn)
{
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr = g_strdup_printf ("(%s %s)", fn, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_back (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) u; return gsurf_verb (a, "cmacs-gsurf-mcp-back"); }
static McpToolResult *
handle_gsurf_forward (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) u; return gsurf_verb (a, "cmacs-gsurf-mcp-forward"); }
static McpToolResult *
handle_gsurf_reload (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) u; return gsurf_verb (a, "cmacs-gsurf-mcp-reload"); }
static McpToolResult *
handle_gsurf_stop (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) u; return gsurf_verb (a, "cmacs-gsurf-mcp-stop"); }
static McpToolResult *
handle_gsurf_get_uri (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) u; return gsurf_verb (a, "cmacs-gsurf-mcp-get-uri"); }
static McpToolResult *
handle_gsurf_get_title (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) u; return gsurf_verb (a, "cmacs-gsurf-mcp-get-title"); }

static McpToolResult *
handle_gsurf_current (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) a; (void) u;
  return gsurf_eval ("(cmacs-gsurf-mcp-current)"); }
static McpToolResult *
handle_gsurf_list (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) a; (void) u;
  return gsurf_eval ("(cmacs-gsurf-mcp-list)"); }
static McpToolResult *
handle_gsurf_modules_list (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) a; (void) u;
  return gsurf_eval ("(cmacs-gsurf-modules-list)"); }

static McpToolResult *
handle_gsurf_eval_js (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *js = json_object_get_string_member_with_default (a, "script", NULL);
  if (js == NULL)
    return missing_arg ("script");
  g_autofree gchar *q = elisp_string (js);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-eval-js %s %s)", q, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_set_zoom (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  if (!json_object_has_member (a, "level"))
    return missing_arg ("level");
  gdouble level = json_object_get_double_member_with_default (a, "level", 1.0);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-set-zoom %g %s)", level, buf);
  return gsurf_eval (expr);
}

/* ── Registration ─────────────────────────────────────────────────── */

static void
add_tool (McpServer *server, const gchar *name, const gchar *desc,
          gboolean read_only, const gchar *schema_json,
          McpToolResult *(*handler) (McpServer *, const gchar *,
                                     JsonObject *, gpointer))
{
  McpTool *tool = mcp_tool_new (name, desc);
  if (read_only)
    mcp_tool_set_read_only_hint (tool, TRUE);
  if (schema_json != NULL)
    {
      JsonNode *schema = cmacs_mcp_schema_from_string (schema_json);
      if (schema != NULL)
        mcp_tool_set_input_schema (tool, schema);
    }
  mcp_server_add_tool (server, tool, handler, NULL, NULL);
  g_object_unref (tool);
}

#define BUF_PROP \
  "\"buffer\":{\"type\":\"string\",\"description\":" \
  "\"gsurf buffer name; defaults to the most recent\"}"

void
cmacs_mcp_tools_gsurf_register (McpServer *server)
{
  add_tool (server, "gsurf_open",
    "Open a URL (or search query) in a new gsurf browser buffer; "
    "returns the buffer name.", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"url\":{\"type\":\"string\",\"description\":\"URL or search query\"}},"
    "\"required\":[\"url\"]}",
    handle_gsurf_open);

  add_tool (server, "gsurf_navigate",
    "Navigate a gsurf buffer to a URL (or search query).", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"url\":{\"type\":\"string\",\"description\":\"URL or search query\"},"
    BUF_PROP "},\"required\":[\"url\"]}",
    handle_gsurf_navigate);

  add_tool (server, "gsurf_back", "Navigate a gsurf buffer back.", FALSE,
    "{\"type\":\"object\",\"properties\":{" BUF_PROP "}}", handle_gsurf_back);
  add_tool (server, "gsurf_forward", "Navigate a gsurf buffer forward.", FALSE,
    "{\"type\":\"object\",\"properties\":{" BUF_PROP "}}", handle_gsurf_forward);
  add_tool (server, "gsurf_reload", "Reload a gsurf buffer.", FALSE,
    "{\"type\":\"object\",\"properties\":{" BUF_PROP "}}", handle_gsurf_reload);
  add_tool (server, "gsurf_stop", "Stop loading in a gsurf buffer.", FALSE,
    "{\"type\":\"object\",\"properties\":{" BUF_PROP "}}", handle_gsurf_stop);

  add_tool (server, "gsurf_get_uri", "Return a gsurf buffer's current URI.",
    TRUE, "{\"type\":\"object\",\"properties\":{" BUF_PROP "}}",
    handle_gsurf_get_uri);
  add_tool (server, "gsurf_get_title", "Return a gsurf buffer's page title.",
    TRUE, "{\"type\":\"object\",\"properties\":{" BUF_PROP "}}",
    handle_gsurf_get_title);
  add_tool (server, "gsurf_current",
    "Return JSON for the current gsurf buffer (buffer/uri/title/progress).",
    TRUE, "{\"type\":\"object\",\"properties\":{}}", handle_gsurf_current);
  add_tool (server, "gsurf_list",
    "Return a JSON array of all open gsurf buffers.", TRUE,
    "{\"type\":\"object\",\"properties\":{}}", handle_gsurf_list);
  add_tool (server, "gsurf_modules_list",
    "Return JSON describing the loaded gsurf modules.", TRUE,
    "{\"type\":\"object\",\"properties\":{}}", handle_gsurf_modules_list);

  add_tool (server, "gsurf_eval_js",
    "Run JavaScript in a gsurf buffer's page (fire-and-forget).", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"script\":{\"type\":\"string\",\"description\":\"JavaScript source\"},"
    BUF_PROP "},\"required\":[\"script\"]}",
    handle_gsurf_eval_js);

  add_tool (server, "gsurf_set_zoom",
    "Set the zoom level (1.0 = 100%) of a gsurf buffer.", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"level\":{\"type\":\"number\",\"description\":\"zoom level\"},"
    BUF_PROP "},\"required\":[\"level\"]}",
    handle_gsurf_set_zoom);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GSURF */
