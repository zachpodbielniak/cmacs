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

static McpToolResult *
handle_query_entities (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *kind = ge_lisp_str (json_object_has_member (a, "kind")
    ? json_object_get_string_member (a, "kind") : NULL);
  double w = json_object_has_member (a, "west")  ? json_object_get_double_member (a, "west")  : -180.0;
  double e = json_object_has_member (a, "east")  ? json_object_get_double_member (a, "east")  :  180.0;
  double so = json_object_has_member (a, "south") ? json_object_get_double_member (a, "south") :  -90.0;
  double no = json_object_has_member (a, "north") ? json_object_get_double_member (a, "north") :   90.0;
  int limit = json_object_has_member (a, "limit")
    ? (int) json_object_get_int_member (a, "limit") : 200;
  (void) s; (void) n; (void) u;
  return ge_eval_result (g_strdup_printf
    ("(progn (require 'cmacs-gnuseye)"
     " (let ((kf %s) (rows nil) (n 0))"
     "  (catch 'done (maphash (lambda (id e)"
     "    (when (and (or (null kf) (eq (plist-get e :kind) (intern kf)))"
     "               (>= (or (plist-get e :lat) 0) %g) (<= (or (plist-get e :lat) 0) %g)"
     "               (>= (or (plist-get e :lon) 0) %g) (<= (or (plist-get e :lon) 0) %g))"
     "      (push (list :id id :kind (plist-get e :kind) :label (plist-get e :label)"
     "                  :lat (plist-get e :lat) :lon (plist-get e :lon)) rows)"
     "      (when (>= (setq n (1+ n)) %d) (throw 'done nil))))"
     "   cmacs-gnuseye--id-index))"
     "  (require 'json) (json-encode (nreverse rows))))",
     kind, so, no, w, e, limit));
}

static McpToolResult *
handle_brief (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return ge_eval_result (g_strdup
    ("(progn (require 'cmacs-gnuseye)"
     " (let ((counts (make-hash-table :test 'eq)) (total 0))"
     "  (maphash (lambda (_ e) (setq total (1+ total))"
     "    (cl-incf (gethash (or (plist-get e :kind) 'generic) counts 0)))"
     "   cmacs-gnuseye--id-index)"
     "  (let (parts) (maphash (lambda (k c) (push (format \"%s:%d\" k c) parts)) counts)"
     "   (format \"%d entities indexed; by kind: %s\""
     "     total (string-join (sort parts #'string<) \", \")))))"));
}

static McpToolResult *
handle_add_geofence (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *name = ge_lisp_str (json_object_has_member (a, "name")
    ? json_object_get_string_member (a, "name") : "fence");
  double lat = json_object_has_member (a, "lat") ? json_object_get_double_member (a, "lat") : 0.0;
  double lon = json_object_has_member (a, "lon") ? json_object_get_double_member (a, "lon") : 0.0;
  double rad = json_object_has_member (a, "radius_km")
    ? json_object_get_double_member (a, "radius_km") : 100.0;
  (void) s; (void) n; (void) u;
  return ge_eval_result (g_strdup_printf
    ("(progn (require 'cmacs-gnuseye) (require 'cmacs-gnuseye-geofence)"
     " (cmacs-gnuseye-add-geofence %s %g %g %g)"
     " (format \"geofence %s @ %g,%g r=%gkm\"))",
     name, lat, lon, rad, name, lat, lon, rad));
}

static McpToolResult *
handle_cii (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return ge_eval_result (g_strdup
    ("(progn (require 'cmacs-gnuseye) (require 'cmacs-gnuseye-intel)"
     " (cmacs-gnuseye-intel--compute-cii)"
     " (let (r) (maphash (lambda (iso v) (push (cons iso v) r))"
     "   cmacs-gnuseye-cii--scores)"
     "  (require 'json)"
     "  (json-encode (seq-take (sort r (lambda (x y) (> (cdr x) (cdr y)))) 15))))"));
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

  ge_add (server, "gnuseye_query_entities",
    "Query indexed entities by KIND and/or a bounding box "
    "(WEST/SOUTH/EAST/NORTH degrees); returns JSON (capped by LIMIT).",
    "{\"type\":\"object\",\"properties\":{"
    "\"kind\":{\"type\":\"string\"},\"west\":{\"type\":\"number\"},"
    "\"south\":{\"type\":\"number\"},\"east\":{\"type\":\"number\"},"
    "\"north\":{\"type\":\"number\"},\"limit\":{\"type\":\"integer\"}}}",
    TRUE, handle_query_entities);

  ge_add (server, "gnuseye_brief",
    "Summarise the entities currently indexed on the globe (counts by kind).",
    NULL, TRUE, handle_brief);

  ge_add (server, "gnuseye_add_geofence",
    "Add a geofence: a circle of RADIUS_KM about LAT, LON named NAME.  "
    "Entities entering/leaving emit podomation events.",
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\"},\"lat\":{\"type\":\"number\"},"
    "\"lon\":{\"type\":\"number\"},\"radius_km\":{\"type\":\"number\"}},"
    "\"required\":[\"name\",\"lat\",\"lon\",\"radius_km\"]}",
    FALSE, handle_add_geofence);

  ge_add (server, "gnuseye_cii",
    "Compute the country-instability index from active signals; returns the "
    "ranked ISO-A3 -> score JSON.",
    NULL, TRUE, handle_cii);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GNUSEYE */
