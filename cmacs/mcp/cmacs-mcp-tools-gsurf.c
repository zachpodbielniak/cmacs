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

/* Build an Elisp string literal from a C string.  The escaping is
   cmacs_dispatch_lisp_escape's (backslash and double quote only; never
   g_strescape, whose octal escapes the reader turns into raw bytes).
   NULL becomes "".  Returns a newly-allocated string; never NULL. */
static gchar *
elisp_string (const gchar *s)
{
  g_autofree gchar *esc = cmacs_dispatch_lisp_escape (s);
  return g_strdup_printf ("\"%s\"", esc);
}

/* Optional string member -> Elisp string literal, or "nil" when absent or
   empty. */
static gchar *
opt_string_arg (JsonObject *a, const gchar *member)
{
  const gchar *v = a ? json_object_get_string_member_with_default (a, member, NULL)
                     : NULL;
  return (v && *v) ? elisp_string (v) : g_strdup ("nil");
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

/* gsurf-lite: render a page offscreen (JS runs, logins persist) and dump
   the post-JS DOM into a real shr-rendered Emacs text buffer.  The
   helpers live in lisp/cmacs/cmacs-gsurf-lite.el; require it so the
   tools work even before a lite buffer was opened interactively. */
static McpToolResult *
handle_gsurf_lite_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *url = json_object_get_string_member_with_default (a, "url", NULL);
  if (url == NULL)
    return missing_arg ("url");
  g_autofree gchar *q = elisp_string (url);
  g_autofree gchar *expr =
    g_strdup_printf ("(progn (require 'cmacs-gsurf-lite) "
                     "(cmacs-gsurf-lite-mcp-open %s))", q);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_extract_text (McpServer *s, const gchar *n, JsonObject *a,
                           gpointer u)
{
  (void) s; (void) n; (void) u;
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(progn (require 'cmacs-gsurf-lite) "
                     "(cmacs-gsurf-lite-mcp-extract-text %s))", buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_download_list (McpServer *s, const gchar *n, JsonObject *a,
                           gpointer u)
{ (void) s; (void) n; (void) a; (void) u;
  return gsurf_eval ("(progn (require 'cmacs-gsurf-downloads) "
                     "(cmacs-gsurf-mcp-download-list))"); }

static McpToolResult *
handle_gsurf_download_cancel (McpServer *s, const gchar *n, JsonObject *a,
                             gpointer u)
{
  (void) s; (void) n; (void) u;
  if (!json_object_has_member (a, "id"))
    return missing_arg ("id");
  gint64 id = json_object_get_int_member_with_default (a, "id", 0);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-download-cancel %lld)", (long long) id);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_snapshot (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *file = json_object_get_string_member_with_default (a, "file", NULL);
  if (file == NULL)
    return missing_arg ("file");
  gboolean full = json_object_get_boolean_member_with_default (a, "full_page", FALSE);
  g_autofree gchar *qf = elisp_string (file);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-snapshot %s %s %s)",
                     qf, full ? "t" : "nil", buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_print_pdf (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *file = json_object_get_string_member_with_default (a, "file", NULL);
  if (file == NULL)
    return missing_arg ("file");
  g_autofree gchar *qf = elisp_string (file);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-print-pdf %s %s)", qf, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_permission_policy (McpServer *s, const gchar *n, JsonObject *a,
                               gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *origin  = json_object_get_string_member_with_default (a, "origin", NULL);
  const gchar *type    = json_object_get_string_member_with_default (a, "type", NULL);
  const gchar *verdict = json_object_get_string_member_with_default (a, "verdict", NULL);
  if (origin == NULL)  return missing_arg ("origin");
  if (type == NULL)    return missing_arg ("type");
  if (verdict == NULL) return missing_arg ("verdict");
  g_autofree gchar *qo = elisp_string (origin);
  g_autofree gchar *qt = elisp_string (type);
  g_autofree gchar *qv = elisp_string (verdict);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-permission-policy %s %s %s)", qo, qt, qv);
  return gsurf_eval (expr);
}

/* ── gsurf 0.5 control surface (cmacs-gsurf-control.el helpers) ───── */

static McpToolResult *
handle_gsurf_click (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  if (!json_object_has_member (a, "x")) return missing_arg ("x");
  if (!json_object_has_member (a, "y")) return missing_arg ("y");
  gdouble x = json_object_get_double_member_with_default (a, "x", 0.0);
  gdouble y = json_object_get_double_member_with_default (a, "y", 0.0);
  gint64 button = json_object_get_int_member_with_default (a, "button", 1);
  if (button < 1 || button > 3)
    button = 1;
  g_autofree gchar *buf = buffer_arg (a);
  gchar xs[G_ASCII_DTOSTR_BUF_SIZE], ys[G_ASCII_DTOSTR_BUF_SIZE];
  g_ascii_dtostr (xs, sizeof xs, x);
  g_ascii_dtostr (ys, sizeof ys, y);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-click %s %s %lld %s)", xs, ys,
                     (long long) button, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_type_text (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *text = json_object_get_string_member_with_default (a, "text", NULL);
  if (text == NULL)
    return missing_arg ("text");
  g_autofree gchar *q = elisp_string (text);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-type-text %s %s)", q, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_press_key (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *key = json_object_get_string_member_with_default (a, "key", NULL);
  if (key == NULL || *key == '\0')
    return missing_arg ("key");
  g_autofree gchar *q = elisp_string (key);
  g_autofree gchar *mods = opt_string_arg (a, "modifiers");
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-press-key %s %s %s)", q, mods, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_click_element (McpServer *s, const gchar *n, JsonObject *a,
                            gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *sel = json_object_get_string_member_with_default (a, "selector", NULL);
  if (sel == NULL || *sel == '\0')
    return missing_arg ("selector");
  g_autofree gchar *q = elisp_string (sel);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-click-element %s %s)", q, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_set_cookie (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *name   = json_object_get_string_member_with_default (a, "name", NULL);
  const gchar *value  = json_object_get_string_member_with_default (a, "value", NULL);
  const gchar *domain = json_object_get_string_member_with_default (a, "domain", NULL);
  if (name == NULL)   return missing_arg ("name");
  if (value == NULL)  return missing_arg ("value");
  if (domain == NULL) return missing_arg ("domain");
  gboolean secure = json_object_get_boolean_member_with_default (a, "secure", FALSE);
  gboolean http_only =
    json_object_get_boolean_member_with_default (a, "http_only", FALSE);
  gint64 expires = json_object_get_int_member_with_default (a, "expires", 0);
  g_autofree gchar *qn = elisp_string (name);
  g_autofree gchar *qv = elisp_string (value);
  g_autofree gchar *qd = elisp_string (domain);
  g_autofree gchar *qp = opt_string_arg (a, "path");
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-set-cookie %s %s %s %s %s %s %lld %s)",
                     qn, qv, qd, qp, secure ? "t" : "nil",
                     http_only ? "t" : "nil", (long long) expires, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_toggle_module (McpServer *s, const gchar *n, JsonObject *a,
                            gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *name = json_object_get_string_member_with_default (a, "name", NULL);
  if (name == NULL || *name == '\0')
    return missing_arg ("name");
  if (!json_object_has_member (a, "enabled"))
    return missing_arg ("enabled");
  gboolean enabled = json_object_get_boolean_member_with_default (a, "enabled", TRUE);
  g_autofree gchar *q = elisp_string (name);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-toggle-module %s %s)", q,
                     enabled ? "t" : "nil");
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_run_action (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  const gchar *action = json_object_get_string_member_with_default (a, "action", NULL);
  if (action == NULL || *action == '\0')
    return missing_arg ("action");
  g_autofree gchar *q = elisp_string (action);
  g_autofree gchar *buf = buffer_arg (a);
  g_autofree gchar *expr =
    g_strdup_printf ("(cmacs-gsurf-mcp-run-action %s %s)", q, buf);
  return gsurf_eval (expr);
}

static McpToolResult *
handle_gsurf_list_actions (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{ (void) s; (void) n; (void) a; (void) u;
  return gsurf_eval ("(cmacs-gsurf-mcp-list-actions)"); }

static McpToolResult *
handle_gsurf_list_containers (McpServer *s, const gchar *n, JsonObject *a,
                              gpointer u)
{ (void) s; (void) n; (void) a; (void) u;
  return gsurf_eval ("(cmacs-gsurf-mcp-list-containers)"); }

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

  add_tool (server, "gsurf_lite_open",
    "Open a URL as eww-style text: gsurf renders it offscreen "
    "(JavaScript runs, logins persist) and the post-JS page is dumped to "
    "a real Emacs text buffer.  Returns the buffer name; read it with "
    "gsurf_extract_text once loaded.", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"url\":{\"type\":\"string\",\"description\":\"URL or search query\"}},"
    "\"required\":[\"url\"]}",
    handle_gsurf_lite_open);

  add_tool (server, "gsurf_extract_text",
    "Return the rendered plain text of a gsurf-lite buffer (newest, or "
    "the named one).  Reads a JS-rendered or logged-in page as clean "
    "text after gsurf_lite_open.", TRUE,
    "{\"type\":\"object\",\"properties\":{" BUF_PROP "}}",
    handle_gsurf_extract_text);

  add_tool (server, "gsurf_download_list",
    "Return a JSON array of known gsurf downloads (id/uri/dest/received/"
    "total/state).", TRUE,
    "{\"type\":\"object\",\"properties\":{}}", handle_gsurf_download_list);

  add_tool (server, "gsurf_download_cancel",
    "Cancel an in-flight gsurf download by id.", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"integer\",\"description\":\"download id\"}},"
    "\"required\":[\"id\"]}", handle_gsurf_download_cancel);

  add_tool (server, "gsurf_snapshot",
    "Save a PNG snapshot of a gsurf buffer to FILE (async); returns the "
    "path.  Set full_page for the whole document.", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"file\":{\"type\":\"string\",\"description\":\"output PNG path\"},"
    "\"full_page\":{\"type\":\"boolean\",\"description\":\"capture full document\"},"
    BUF_PROP "},\"required\":[\"file\"]}", handle_gsurf_snapshot);

  add_tool (server, "gsurf_print_pdf",
    "Print a gsurf buffer to a PDF at FILE (async); returns the path.",
    FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"file\":{\"type\":\"string\",\"description\":\"output PDF path\"},"
    BUF_PROP "},\"required\":[\"file\"]}", handle_gsurf_print_pdf);

  add_tool (server, "gsurf_permission_policy",
    "Set a permission policy for an origin and type "
    "(verdict \"allow\" or \"deny\").", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"origin\":{\"type\":\"string\",\"description\":\"scheme://host:port\"},"
    "\"type\":{\"type\":\"string\",\"description\":\"geolocation/notification/media/...\"},"
    "\"verdict\":{\"type\":\"string\",\"description\":\"allow or deny\"}},"
    "\"required\":[\"origin\",\"type\",\"verdict\"]}",
    handle_gsurf_permission_policy);

  /* gsurf 0.5 control surface.  Input is trusted (native GTK events) and
     needs the page to have been on screen once; keyboard focus is
     borrowed for the call and handed back to the editor. */
  add_tool (server, "gsurf_click",
    "Click at x,y (CSS pixels from the page's top-left, as "
    "getBoundingClientRect reports) in a gsurf page with a trusted click.",
    FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"x\":{\"type\":\"number\",\"description\":\"CSS px from the left\"},"
    "\"y\":{\"type\":\"number\",\"description\":\"CSS px from the top\"},"
    "\"button\":{\"type\":\"integer\",\"description\":\"1 left (default), 2 middle, 3 right\"},"
    BUF_PROP "},\"required\":[\"x\",\"y\"]}", handle_gsurf_click);

  add_tool (server, "gsurf_type_text",
    "Type text into whatever has focus in a gsurf page, one trusted key "
    "press per character (newline = Enter).  Focus a field first with "
    "gsurf_click_element.", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"text\":{\"type\":\"string\",\"description\":\"UTF-8 text\"},"
    BUF_PROP "},\"required\":[\"text\"]}", handle_gsurf_type_text);

  add_tool (server, "gsurf_press_key",
    "Press and release one key in a gsurf page (trusted).  key is a DOM "
    "or X name (Enter, Tab, Escape, ArrowDown, PageDown, a, ...).", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"key\":{\"type\":\"string\",\"description\":\"key name or one character\"},"
    "\"modifiers\":{\"type\":\"string\",\"description\":\"e.g. ctrl+shift (ctrl, shift, alt/meta, super)\"},"
    BUF_PROP "},\"required\":[\"key\"]}", handle_gsurf_press_key);

  add_tool (server, "gsurf_click_element",
    "Click the first element matching a CSS selector in a gsurf page: it "
    "is scrolled into view, focused and clicked at its centre.  "
    "Asynchronous: returns at once; the outcome goes to the echo area.",
    FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"selector\":{\"type\":\"string\",\"description\":\"CSS selector\"},"
    BUF_PROP "},\"required\":[\"selector\"]}", handle_gsurf_click_element);

  add_tool (server, "gsurf_set_cookie",
    "Add a cookie to a gsurf view's session (its container's cookie jar "
    "for a view in a container).", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\"},"
    "\"value\":{\"type\":\"string\"},"
    "\"domain\":{\"type\":\"string\",\"description\":\"example.com, or .example.com for subdomains too\"},"
    "\"path\":{\"type\":\"string\",\"description\":\"default /\"},"
    "\"secure\":{\"type\":\"boolean\"},"
    "\"http_only\":{\"type\":\"boolean\"},"
    "\"expires\":{\"type\":\"integer\",\"description\":\"Unix seconds; 0 = session cookie\"},"
    BUF_PROP "},\"required\":[\"name\",\"value\",\"domain\"]}",
    handle_gsurf_set_cookie);

  add_tool (server, "gsurf_toggle_module",
    "Enable or disable a loaded gsurf module by name (adblock, dark_mode, "
    "hardening, containers, form_autofill, modal, ...).", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\",\"description\":\"module name\"},"
    "\"enabled\":{\"type\":\"boolean\"}},"
    "\"required\":[\"name\",\"enabled\"]}", handle_gsurf_toggle_module);

  add_tool (server, "gsurf_run_action",
    "Run a gsurf action by name on a gsurf buffer (see gsurf_list_actions): "
    "core ones map to editor commands, the rest go to the modules "
    "(dark-mode-toggle, dark-mode-toggle-site, form-autofill, ...).", FALSE,
    "{\"type\":\"object\",\"properties\":{"
    "\"action\":{\"type\":\"string\",\"description\":\"action name\"},"
    BUF_PROP "},\"required\":[\"action\"]}", handle_gsurf_run_action);

  add_tool (server, "gsurf_list_actions",
    "Return a JSON array of every gsurf action: name, description and "
    "handler (cmacs or module).", TRUE,
    "{\"type\":\"object\",\"properties\":{}}", handle_gsurf_list_actions);

  add_tool (server, "gsurf_list_containers",
    "Return a JSON array of gsurf browsing containers (id, name, color, "
    "temporary, views, proxy).", TRUE,
    "{\"type\":\"object\",\"properties\":{}}", handle_gsurf_list_containers);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GSURF */
