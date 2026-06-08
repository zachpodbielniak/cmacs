/*
 * cmacs-mcp-tools-gnuseye.c — GNU's Eye globe MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools that drive the GNU's Eye live globe by dispatching Elisp.
 * The MCP `eval' tool already reaches every DEFUN; these add typed schemas
 * so an agent can open the globe, toggle data layers, and fly the camera
 * without hand-writing Elisp.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_GNUSEYE)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Render STR as an Elisp string literal, or `nil' when NULL.  Caller frees. */
static gchar *
ge_lisp_str (const gchar *str)
{
  GString *s;
  const gchar *p;
  if (str == NULL)
    return g_strdup ("nil");
  s = g_string_new ("\"");
  for (p = str; *p; p++)
    {
      if (*p == '"' || *p == '\\')
        g_string_append_c (s, '\\');
      g_string_append_c (s, *p);
    }
  g_string_append_c (s, '"');
  return g_string_free (s, FALSE);
}

/* Run ELISP and return its value (or error) as the tool result.  Takes
 * ownership of ELISP. */
static McpToolResult *
ge_eval_result (gchar *elisp)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *src = elisp;
  g_autofree gchar *out = cmacs_dispatch_eval (src, &error);
  McpToolResult *result = mcp_tool_result_new (out == NULL);
  mcp_tool_result_add_text (result,
    out ? out : (error ? error->message : "error"));
  return result;
}

static McpToolResult *
handle_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return ge_eval_result (g_strdup
    ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye) \"opened\")"));
}

static McpToolResult *
handle_list_layers (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return ge_eval_result (g_strdup
    ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye--load-layers)"
     " (let (r) (maphash (lambda (k v)"
     "   (push (list k :on (and (cmacs-gnuseye-layer-enabled v) t)"
     "               :group (cmacs-gnuseye-layer-group v)"
     "               :title (cmacs-gnuseye-layer-title v)) r))"
     "  cmacs-gnuseye--layers) (format \"%S\" (nreverse r))))"));
}

static McpToolResult *
handle_toggle_layer (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *name = ge_lisp_str (json_object_has_member (a, "name")
    ? json_object_get_string_member (a, "name") : NULL);
  (void) s; (void) n; (void) u;
  return ge_eval_result (g_strdup_printf
    ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye--load-layers)"
     " (let ((l (gethash (intern %s) cmacs-gnuseye--layers)))"
     "  (if (null l) \"unknown layer\""
     "    (if (cmacs-gnuseye-layer-enabled l)"
     "        (progn (cmacs-gnuseye--disable-layer l) (format \"%s off\" %s))"
     "      (progn (cmacs-gnuseye--enable-layer l) (format \"%s on\" %s))))))",
     name, "%s", name, "%s", name));
}

static McpToolResult *
handle_fly_to (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  double lat = json_object_has_member (a, "lat")
    ? json_object_get_double_member (a, "lat") : 0.0;
  double lon = json_object_has_member (a, "lon")
    ? json_object_get_double_member (a, "lon") : 0.0;
  double range = json_object_has_member (a, "range")
    ? json_object_get_double_member (a, "range") : 14.0;
  (void) s; (void) n; (void) u;
  return ge_eval_result (g_strdup_printf
    ("(progn (require 'cmacs-gnuseye)"
     " (if (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))"
     "   (progn (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer %g %g %g t)"
     "          (format \"flew to %g,%g\"))"
     "  \"no globe open\"))",
     lat, lon, range, lat, lon));
}

static McpToolResult *
handle_refresh (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return ge_eval_result (g_strdup
    ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye-refresh-all) \"refreshing\")"));
}

static void
ge_add (McpServer *server, const gchar *name, const gchar *desc,
        const gchar *schema_json, gboolean read_only,
        McpToolResult *(*handler) (McpServer *, const gchar *,
                                   JsonObject *, gpointer))
{
  McpTool *tool = mcp_tool_new (name, desc);
  if (schema_json)
    mcp_tool_set_input_schema (tool, cmacs_mcp_schema_from_string (schema_json));
  if (read_only)
    mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handler, NULL, NULL);
  g_object_unref (tool);
}

void
cmacs_mcp_tools_gnuseye_register (McpServer *server)
{
  ge_add (server, "gnuseye_open",
    "Open the GNU's Eye live planetary globe buffer.",
    NULL, FALSE, handle_open);

  ge_add (server, "gnuseye_list_layers",
    "List GNU's Eye data layers with their on/off state and group.",
    NULL, TRUE, handle_list_layers);

  ge_add (server, "gnuseye_toggle_layer",
    "Toggle a data layer on/off by NAME (e.g. satellites, aircraft, "
    "vessels, quakes, launches, fires).",
    "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},"
    "\"required\":[\"name\"]}", FALSE, handle_toggle_layer);

  ge_add (server, "gnuseye_fly_to",
    "Fly the globe camera to LAT, LON (degrees); optional RANGE world units.",
    "{\"type\":\"object\",\"properties\":{"
    "\"lat\":{\"type\":\"number\"},\"lon\":{\"type\":\"number\"},"
    "\"range\":{\"type\":\"number\"}},\"required\":[\"lat\",\"lon\"]}",
    FALSE, handle_fly_to);

  ge_add (server, "gnuseye_refresh",
    "Refresh every enabled GNU's Eye layer now.",
    NULL, FALSE, handle_refresh);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GNUSEYE */
