/*
 * cmacs-mcp-tools-gowl.c — Gowl Wayland compositor MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Direct C dispatch to the gowl compositor, bypassing Elisp for
 * performance.  Uses the cmacs_dispatch_gowl_*() functions from
 * cmacs-eval-dispatch.c.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_GOWL)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Helper: dispatch a gowl function returning gchar*, wrap in result. */
static McpToolResult *
gowl_result (gchar *str, GError *error)
{
  McpToolResult *result;
  if (str == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        error ? error->message : "Unknown gowl error");
    }
  else
    {
      result = mcp_tool_result_new (FALSE);
      mcp_tool_result_add_text (result, str);
      g_free (str);
    }
  return result;
}

/* Helper: dispatch an elisp EXPR string, wrap the result. */
static McpToolResult *
gowl_eval (const gchar *expr)
{
  GError *error = NULL;
  gchar *str = cmacs_dispatch_eval (expr, &error);
  McpToolResult *result = gowl_result (str, error);
  g_clear_error (&error);
  return result;
}

/* Helper: validate a "by" field, defaulting to app-id. */
static const gchar *
gowl_by_field (JsonObject *a)
{
  const gchar *by = json_object_get_string_member_with_default (a, "by", NULL);
  if (by != NULL && g_strcmp0 (by, "title") == 0)
    return "title";
  return "app-id";
}

/* ── Tool handlers ────────────────────────────────────────────────── */

static McpToolResult *
handle_gowl_list_clients (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_list_clients (&error), error);
}

static McpToolResult *
handle_gowl_focused_client (McpServer *s, const gchar *n,
                             JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_focused_client (&error), error);
}

static McpToolResult *
handle_gowl_spawn (McpServer *s, const gchar *n,
                   JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *command;
  (void) s; (void) n; (void) u;
  command = json_object_get_string_member_with_default (a, "command", NULL);
  if (command == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: command");
      return r;
    }
  return gowl_result (cmacs_dispatch_gowl_spawn (command, &error), error);
}

static McpToolResult *
handle_gowl_list_monitors (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_list_monitors (&error), error);
}

static McpToolResult *
handle_gowl_list_keybinds (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_list_keybinds (&error), error);
}

static McpToolResult *
handle_gowl_find_client (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *pattern, *by;
  (void) s; (void) n; (void) u;
  pattern = json_object_get_string_member_with_default (a, "pattern", NULL);
  by = json_object_get_string_member_with_default (a, "by", NULL);
  if (pattern == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: pattern");
      return r;
    }
  return gowl_result (
    cmacs_dispatch_gowl_find_client (pattern, by ? by : "app-id", &error),
    error);
}

static McpToolResult *
handle_gowl_reload_config (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_reload_config (&error), error);
}

/* ── Input recording ──────────────────────────────────────────────
 *
 * The observing counterpart to send_keys.  These are separate tools
 * behind a separate switch on purpose: gowl's `input-recording' config
 * key gates them and defaults to off, and nothing that enables input
 * *injection* enables capture.  An agent allowed to click must not
 * thereby be allowed to watch the user type.
 *
 * There is no push notification of a state change.  Every payload
 * carries `active' and `stop_reason', so a caller that is already
 * draining learns on its next call that the recording ended and why
 * (its deadline, Super+Shift+Escape, or consent withdrawn); a caller
 * that is not draining polls gowl_recording_status.
 */

/* Reads an optional non-negative integer argument.  A missing or
 * non-positive value means "use the recorder's default" -- there is no
 * spelling for "unbounded", because there is no unbounded here. */
static guint
gowl_uint_arg (JsonObject *a, const gchar *name)
{
  gint64 val;

  if (a == NULL || !json_object_has_member (a, name))
    return 0;

  val = json_object_get_int_member (a, name);
  if (val <= 0)
    return 0;
  if (val > (gint64) G_MAXUINT)
    return G_MAXUINT;

  return (guint) val;
}

static McpToolResult *
handle_gowl_start_recording (McpServer *s, const gchar *n,
                             JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) u;
  return gowl_result (
    cmacs_dispatch_gowl_start_recording (
      gowl_uint_arg (a, "max_seconds"),
      gowl_uint_arg (a, "max_events"), &error),
    error);
}

static McpToolResult *
handle_gowl_drain_recording (McpServer *s, const gchar *n,
                             JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *token;
  (void) s; (void) n; (void) u;

  token = json_object_get_string_member_with_default (a, "token", NULL);
  if (token == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: token");
      return r;
    }
  return gowl_result (
    cmacs_dispatch_gowl_drain_recording (token, &error), error);
}

static McpToolResult *
handle_gowl_stop_recording (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *token;
  (void) s; (void) n; (void) u;

  token = json_object_get_string_member_with_default (a, "token", NULL);
  if (token == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: token");
      return r;
    }
  return gowl_result (
    cmacs_dispatch_gowl_stop_recording (token, &error), error);
}

static McpToolResult *
handle_gowl_recording_status (McpServer *s, const gchar *n,
                              JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_gowl_recording_status (&error), error);
}

/* NOTE: gowl_lock / gowl_unlock are intentionally NOT exposed as MCP tools --
 * an AI agent should not be able to lock or unlock the session screen.  They
 * remain available over D-Bus, emacsctl, and cmacsgi. */

static McpToolResult *
handle_screensaver_set_wallpaper (McpServer *s, const gchar *n,
                                  JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *config = NULL;
  (void) s; (void) n; (void) u;
  if (a != NULL && json_object_has_member (a, "config"))
    config = json_object_get_string_member_with_default (a, "config", NULL);
  return gowl_result (
    cmacs_dispatch_screensaver_set_wallpaper (config, &error), error);
}

static McpToolResult *
handle_screensaver_stop_wallpaper (McpServer *s, const gchar *n,
                                   JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (
    cmacs_dispatch_screensaver_stop_wallpaper (&error), error);
}

static McpToolResult *
handle_screensaver_list_configs (McpServer *s, const gchar *n,
                                 JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (
    cmacs_dispatch_screensaver_list_configs (&error), error);
}

static McpToolResult *
handle_screensaver_status (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_screensaver_status (&error), error);
}

static McpToolResult *
handle_screensaver_restart (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_screensaver_restart (&error), error);
}

static McpToolResult *
handle_screensaver_pause (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_screensaver_pause (&error), error);
}

static McpToolResult *
handle_screensaver_resume (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  (void) s; (void) n; (void) a; (void) u;
  return gowl_result (cmacs_dispatch_screensaver_resume (&error), error);
}

static McpToolResult *
handle_screensaver_set_fps (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  gint64 fps;
  (void) s; (void) n; (void) u;
  fps = a && json_object_has_member (a, "fps")
        ? json_object_get_int_member (a, "fps") : 0;
  return gowl_result (cmacs_dispatch_screensaver_set_fps ((gint) fps, &error),
                      error);
}

static McpToolResult *
handle_gowl_set_monitor_transform (McpServer *s, const gchar *n,
                                    JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  const gchar *name;
  gint64 xform;
  (void) s; (void) n; (void) u;

  name = json_object_get_string_member_with_default (a, "name", NULL);
  if (name == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: name");
      return r;
    }
  if (!json_object_has_member (a, "transform"))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: transform");
      return r;
    }
  xform = json_object_get_int_member (a, "transform");
  return gowl_result (
    cmacs_dispatch_gowl_set_monitor_transform (name, (gint)xform, &error),
    error);
}

static McpToolResult *
handle_gowl_focus_client (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  const gchar *pattern;
  g_autofree gchar *ep = NULL, *expr = NULL;
  (void) s; (void) n; (void) u;

  pattern = json_object_get_string_member_with_default (a, "pattern", NULL);
  if (pattern == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: pattern");
      return r;
    }
  ep = cmacs_dispatch_lisp_escape (pattern);
  expr = g_strdup_printf (
    "(let ((c (gowl-find-client \"%s\" '%s)))"
    "  (if c (progn (gowl-focus-client c) \"focused\")"
    "    (error \"no client matching pattern\")))",
    ep, gowl_by_field (a));
  return gowl_eval (expr);
}

static McpToolResult *
handle_gowl_close_client (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  const gchar *pattern;
  g_autofree gchar *ep = NULL, *expr = NULL;
  (void) s; (void) n; (void) u;

  pattern = json_object_get_string_member_with_default (a, "pattern", NULL);
  if (pattern == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: pattern");
      return r;
    }
  ep = cmacs_dispatch_lisp_escape (pattern);
  expr = g_strdup_printf (
    "(let ((c (gowl-find-client \"%s\" '%s)))"
    "  (if c (progn (gowl-close-client c) \"closed\")"
    "    (error \"no client matching pattern\")))",
    ep, gowl_by_field (a));
  return gowl_eval (expr);
}

static McpToolResult *
handle_gowl_set_client_geometry (McpServer *s, const gchar *n,
                                 JsonObject *a, gpointer u)
{
  const gchar *pattern;
  g_autofree gchar *ep = NULL, *expr = NULL;
  gint64 x, y, w, h;
  (void) s; (void) n; (void) u;

  pattern = json_object_get_string_member_with_default (a, "pattern", NULL);
  if (pattern == NULL
      || !json_object_has_member (a, "x")
      || !json_object_has_member (a, "y")
      || !json_object_has_member (a, "width")
      || !json_object_has_member (a, "height"))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r,
        "Missing required arguments: pattern, x, y, width, height");
      return r;
    }
  x = json_object_get_int_member (a, "x");
  y = json_object_get_int_member (a, "y");
  w = json_object_get_int_member (a, "width");
  h = json_object_get_int_member (a, "height");
  ep = cmacs_dispatch_lisp_escape (pattern);
  expr = g_strdup_printf (
    "(let ((c (gowl-find-client \"%s\" '%s)))"
    "  (if c (progn (gowl-client-set-geometry c %ld %ld %ld %ld)"
    "               \"geometry set\")"
    "    (error \"no client matching pattern\")))",
    ep, gowl_by_field (a),
    (long) x, (long) y, (long) w, (long) h);
  return gowl_eval (expr);
}

static McpToolResult *
handle_gowl_set_layout (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  const gchar *layout;
  g_autofree gchar *el = NULL, *expr = NULL;
  (void) s; (void) n; (void) u;

  layout = json_object_get_string_member_with_default (a, "layout", NULL);
  if (layout == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: layout");
      return r;
    }
  el = cmacs_dispatch_lisp_escape (layout);
  expr = g_strdup_printf (
    "(progn (gowl-set-layout \"%s\") \"layout set\")", el);
  return gowl_eval (expr);
}

static McpToolResult *
handle_gowl_workspace_list (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_eval ("(prin1-to-string (gowl-workspace-list))");
}

static McpToolResult *
handle_gowl_workspace_switch (McpServer *s, const gchar *n,
                              JsonObject *a, gpointer u)
{
  g_autofree gchar *expr = NULL;
  gint64 id;
  (void) s; (void) n; (void) u;

  if (!json_object_has_member (a, "id"))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: id");
      return r;
    }
  id = json_object_get_int_member (a, "id");
  expr = g_strdup_printf (
    "(if (gowl-workspace-switch %ld) \"switched\""
    "  \"workspace unchanged or unknown id\")",
    (long) id);
  return gowl_eval (expr);
}

static McpToolResult *
handle_gowl_screenshot (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *path = NULL, *expr = NULL, *str = NULL;
  const gchar *pattern, *mode;
  McpToolResult *result;
  (void) s; (void) n; (void) u;

  path = g_strdup_printf ("%s/cmacs-mcp-shot-%u.png",
                          g_get_tmp_dir (), g_random_int ());
  pattern = json_object_get_string_member_with_default (a, "client", NULL);
  mode = json_object_get_string_member_with_default (a, "mode", NULL);
  if (mode == NULL
      || (g_strcmp0 (mode, "desktop") != 0
          && g_strcmp0 (mode, "window") != 0
          && g_strcmp0 (mode, "all") != 0))
    mode = "desktop";

  if (pattern != NULL)
    {
      g_autofree gchar *ep = cmacs_dispatch_lisp_escape (pattern);
      expr = g_strdup_printf (
        "(let ((c (gowl-find-client \"%s\" '%s)))"
        "  (if c (let ((shot (gowl-screenshot-client c)))"
        "          (when shot"
        "            (apply #'gowl-screenshot-save-png"
        "                   (append shot (list \"%s\"))) t))"
        "    (error \"no client matching pattern\")))",
        ep, gowl_by_field (a), path);
    }
  else
    expr = g_strdup_printf (
      "(gowl-screenshot '%s \"%s\" t)", mode, path);

  str = cmacs_dispatch_eval (expr, &error);
  if (str == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, error->message);
      return r;
    }

  result = mcp_tool_result_new (FALSE);
  if (!cmacs_mcp_result_add_png_file (result, path))
    {
      mcp_tool_result_unref (result);
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, "Screenshot capture produced no image");
    }
  return result;
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_gowl_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("gowl_list_clients",
    "List all Wayland clients (JSON array with id, title, app-id, tags, geometry).");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_list_clients, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_focused_client",
    "Get info about the currently focused Wayland client.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_focused_client, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_spawn",
    "Spawn a command in the Wayland compositor.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"command\":{\"type\":\"string\",\"description\":\"Shell command to spawn\"}"
    "},\"required\":[\"command\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_spawn, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_list_monitors",
    "List monitors (JSON array with name, geometry, mode, scale, layout).");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_list_monitors, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_list_keybinds",
    "List all compositor keybinds.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_list_keybinds, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_find_client",
    "Find a Wayland client by app-id or title pattern.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"pattern\":{\"type\":\"string\",\"description\":\"Search pattern\"},"
    "\"by\":{\"type\":\"string\",\"enum\":[\"app-id\",\"title\"],"
    "\"description\":\"Search field (default: app-id)\"}"
    "},\"required\":[\"pattern\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_find_client, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_reload_config",
    "Reload the gowl compositor configuration from YAML.");
  mcp_server_add_tool (server, tool, handle_gowl_reload_config, NULL, NULL);
  g_object_unref (tool);

  /* gowl_lock / gowl_unlock are deliberately omitted -- locking the screen
   * is not an action an AI agent should take (available via D-Bus / emacsctl
   * / cmacsgi instead). */

  tool = mcp_tool_new ("screensaver_set_wallpaper",
    "Set the animated libregnum screensaver wallpaper to a named config "
    "from cmacs-screensaver-configs (omit `config' for the default).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"config\":{\"type\":\"string\",\"description\":"
    "\"Config name from cmacs-screensaver-configs (e.g. blackhole-cool)\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_screensaver_set_wallpaper,
                       NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("screensaver_stop_wallpaper",
    "Stop the animated screensaver wallpaper, restoring the static one.");
  mcp_server_add_tool (server, tool, handle_screensaver_stop_wallpaper,
                       NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("screensaver_list_configs",
    "List the available screensaver config names (one per line).");
  mcp_server_add_tool (server, tool, handle_screensaver_list_configs,
                       NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("screensaver_status",
    "Get the out-of-process screensaver renderer status as a plist "
    "(:running :pid :fps :paused :gave-up :targets :wallpaper :lock "
    ":last-error).");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_screensaver_status, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("screensaver_restart",
    "Kill and respawn the screensaver render child, re-applying the active "
    "wallpaper/lock sessions (recovery).");
  mcp_server_add_tool (server, tool, handle_screensaver_restart, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("screensaver_pause",
    "Pause the animated wallpaper/lock rendering (the render child stops "
    "drawing; the GPU goes idle).");
  mcp_server_add_tool (server, tool, handle_screensaver_pause, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("screensaver_resume",
    "Resume the animated wallpaper/lock rendering after a pause.");
  mcp_server_add_tool (server, tool, handle_screensaver_resume, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("screensaver_set_fps",
    "Set the animated wallpaper/lock target frame rate (1-240).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"fps\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":240,"
            "\"description\":\"Target frames per second\"}"
    "},\"required\":[\"fps\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_screensaver_set_fps, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("gowl_set_monitor_transform",
    "Set the wl_output transform for a monitor (rotation/flip). "
    "transform is an integer 0-7: 0=normal, 1=90, 2=180, 3=270, "
    "4=flipped, 5=flipped-90, 6=flipped-180, 7=flipped-270. "
    "To persist across sessions, add `transform:` under the "
    "matching output name in the YAML `monitors:` block.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"name\":{\"type\":\"string\","
              "\"description\":\"Output name (e.g. eDP-1)\"},"
    "\"transform\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":7,"
                   "\"description\":\"Transform code 0-7\"}"
    "},\"required\":[\"name\",\"transform\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_set_monitor_transform,
                       NULL, NULL);
  g_object_unref (tool);

  /* gowl_focus_client */
  tool = mcp_tool_new ("gowl_focus_client",
    "Give keyboard focus to the Wayland client matching a pattern.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"pattern\":{\"type\":\"string\",\"description\":\"Match pattern\"},"
    "\"by\":{\"type\":\"string\",\"enum\":[\"app-id\",\"title\"],"
    "\"description\":\"Match field (default: app-id)\"}"
    "},\"required\":[\"pattern\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_focus_client, NULL, NULL);
  g_object_unref (tool);

  /* gowl_close_client */
  tool = mcp_tool_new ("gowl_close_client",
    "Close the Wayland client matching a pattern.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"pattern\":{\"type\":\"string\",\"description\":\"Match pattern\"},"
    "\"by\":{\"type\":\"string\",\"enum\":[\"app-id\",\"title\"],"
    "\"description\":\"Match field (default: app-id)\"}"
    "},\"required\":[\"pattern\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_destructive_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_close_client, NULL, NULL);
  g_object_unref (tool);

  /* gowl_set_client_geometry */
  tool = mcp_tool_new ("gowl_set_client_geometry",
    "Move and resize the Wayland client matching a pattern in one call.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"pattern\":{\"type\":\"string\",\"description\":\"Match pattern\"},"
    "\"by\":{\"type\":\"string\",\"enum\":[\"app-id\",\"title\"],"
    "\"description\":\"Match field (default: app-id)\"},"
    "\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"},"
    "\"width\":{\"type\":\"integer\"},\"height\":{\"type\":\"integer\"}"
    "},\"required\":[\"pattern\",\"x\",\"y\",\"width\",\"height\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_set_client_geometry,
                       NULL, NULL);
  g_object_unref (tool);

  /* gowl_set_layout */
  tool = mcp_tool_new ("gowl_set_layout",
    "Set the tiling layout: \"tile\", \"monocle\", or \"float\".");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"layout\":{\"type\":\"string\","
    "\"enum\":[\"tile\",\"monocle\",\"float\"],"
    "\"description\":\"Layout name\"}"
    "},\"required\":[\"layout\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_set_layout, NULL, NULL);
  g_object_unref (tool);

  /* gowl_workspace_list */
  tool = mcp_tool_new ("gowl_workspace_list",
    "List workspaces as plists (:id :name :tag-mask).");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_workspace_list,
                       NULL, NULL);
  g_object_unref (tool);

  /* gowl_workspace_switch */
  tool = mcp_tool_new ("gowl_workspace_switch",
    "Switch to the workspace with the given id.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"integer\",\"description\":\"Workspace id\"}"
    "},\"required\":[\"id\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_workspace_switch,
                       NULL, NULL);
  g_object_unref (tool);

  /* gowl_screenshot */
  tool = mcp_tool_new ("gowl_screenshot",
    "Capture a screenshot and return it as a PNG image. With no "
    "arguments captures the whole desktop; mode selects "
    "desktop/window/all; client captures one matching client.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"mode\":{\"type\":\"string\","
    "\"enum\":[\"desktop\",\"window\",\"all\"],"
    "\"description\":\"Capture mode (default: desktop)\"},"
    "\"client\":{\"type\":\"string\","
    "\"description\":\"Capture the client matching this pattern\"},"
    "\"by\":{\"type\":\"string\",\"enum\":[\"app-id\",\"title\"],"
    "\"description\":\"Client match field (default: app-id)\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_screenshot, NULL, NULL);
  g_object_unref (tool);

  /* gowl_start_recording */
  tool = mcp_tool_new ("gowl_start_recording",
    "Record real keyboard and pointer input so a human demonstration "
    "can be turned into a procedure. Returns a token for "
    "gowl_drain_recording and gowl_stop_recording. Bounded: the ring "
    "holds at most max_events (older events are dropped and counted) "
    "and the recording stops itself after max_seconds. Requires gowl's "
    "`input-recording' config key, which is separate from send_keys "
    "and off by default. While it runs the screen is framed in red and "
    "Super+Shift+Escape stops it. Capture is suppressed on the lock "
    "screen and for windows on the deny list, but gowl CANNOT see a "
    "password field inside an ordinary window -- review a trace before "
    "storing or sharing it.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"max_seconds\":{\"type\":\"integer\","
    "\"description\":\"Stop automatically after this many seconds "
    "(default 120, maximum 3600)\"},"
    "\"max_events\":{\"type\":\"integer\","
    "\"description\":\"Ring size in events (default 4096, "
    "maximum 100000)\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_open_world_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_start_recording,
                       NULL, NULL);
  g_object_unref (tool);

  /* gowl_drain_recording */
  tool = mcp_tool_new ("gowl_drain_recording",
    "Take everything recorded since the last drain and leave the "
    "recording running. The reply carries dropped (since the last "
    "drain) and dropped_total, so a demonstration that overflowed the "
    "ring is reported rather than passed off as complete, plus active "
    "and stop_reason.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"token\":{\"type\":\"string\","
    "\"description\":\"Token from gowl_start_recording\"}"
    "},\"required\":[\"token\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_drain_recording,
                       NULL, NULL);
  g_object_unref (tool);

  /* gowl_stop_recording */
  tool = mcp_tool_new ("gowl_stop_recording",
    "Stop the recording and take the tail, in the same shape "
    "gowl_drain_recording returns. Stopping a recording that already "
    "stopped itself still returns its remaining events exactly once.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"token\":{\"type\":\"string\","
    "\"description\":\"Token from gowl_start_recording\"}"
    "},\"required\":[\"token\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_stop_recording,
                       NULL, NULL);
  g_object_unref (tool);

  /* gowl_recording_status */
  tool = mcp_tool_new ("gowl_recording_status",
    "Whether an input recording is running, its token, limits and "
    "counters, without consuming anything. Poll this to notice that a "
    "recording started, stopped, or was stopped from the keyboard.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_recording_status,
                       NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GOWL */
