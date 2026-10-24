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

/* ── Macros, the recorder, voice, the screen, the clipboard ─────────
 *
 * Thin: each is one call to an Elisp function in cmacs-gowl-macro.el or
 * cmacs-gowl-grab.el, so the MCP tool, Lisp and the default keys share
 * one path.  Strings go into the generated Lisp through
 * cmacs_dispatch_lisp_escape(), and an error in the Lisp (a module
 * reply of ERROR) comes back as an MCP error with its message. */

/* Like gowl_eval, but a string result comes back as the text itself --
   JSON from the module, OCR text, a colour -- not prin1-quoted. */
static McpToolResult *
gowl_eval_raw (const gchar *expr)
{
  GError *error = NULL;
  gchar *str = cmacs_dispatch_eval_string (expr, &error);
  McpToolResult *result = gowl_result (str, error);
  g_clear_error (&error);
  return result;
}

static McpToolResult *
gowl_missing (const gchar *what)
{
  McpToolResult *r = mcp_tool_result_new (TRUE);
  g_autofree gchar *msg = g_strdup_printf ("Missing required argument: %s",
                                           what);
  mcp_tool_result_add_text (r, msg);
  return r;
}

/* (FN "ESCAPED-LINE") */
static McpToolResult *
gowl_eval_line (const gchar *fn, const gchar *line)
{
  g_autofree gchar *el = cmacs_dispatch_lisp_escape (line);
  g_autofree gchar *expr = g_strdup_printf ("(%s \"%s\")", fn, el);
  return gowl_eval_raw (expr);
}

static McpToolResult *
handle_gowl_macro_run (McpServer *s, const gchar *n,
                       JsonObject *a, gpointer u)
{
  const gchar *name;
  GString *line;
  McpToolResult *r;
  (void) s; (void) n; (void) u;

  name = json_object_get_string_member_with_default (a, "name", NULL);
  if (name == NULL || *name == '\0')
    return gowl_missing ("name");
  line = g_string_new ("macro-run --trigger=api -- ");
  {
    g_autofree gchar *q = g_shell_quote (name);
    g_string_append (line, q);
  }
  if (json_object_has_member (a, "args"))
    {
      JsonArray *args = json_object_get_array_member (a, "args");
      guint i;
      for (i = 0; args != NULL && i < json_array_get_length (args); i++)
        {
          g_autofree gchar *q
            = g_shell_quote (json_array_get_string_element (args, i));
          g_string_append_printf (line, " %s", q);
        }
    }
  r = gowl_eval_line ("cmacs-gowl-macro-command", line->str);
  g_string_free (line, TRUE);
  return r;
}

static McpToolResult *
handle_gowl_macro_list (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_eval_line ("cmacs-gowl-macro-command", "macro-list");
}

static McpToolResult *
handle_gowl_macro_status (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_eval_line ("cmacs-gowl-macro-command", "macro-status");
}

static McpToolResult *
handle_gowl_macro_stop (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  const gchar *which;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  which = json_object_get_string_member_with_default (a, "which", NULL);
  if (which != NULL && *which != '\0')
    {
      g_autofree gchar *q = g_shell_quote (which);
      line = g_strdup_printf ("macro-stop %s", q);
    }
  else
    line = g_strdup ("macro-stop");
  return gowl_eval_line ("cmacs-gowl-macro-command", line);
}

/* The recorder.  `start' asks for gowl's input-recording consent: the
   Super+Alt+r key needs none because the person pressed it, an agent
   asking is a different thing. */
static McpToolResult *
handle_gowl_macro_record (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  const gchar *action, *name;
  g_autofree gchar *ea = NULL, *en = NULL, *expr = NULL;
  (void) s; (void) n; (void) u;

  action = json_object_get_string_member_with_default (a, "action", "status");
  name = json_object_get_string_member_with_default (a, "name", NULL);
  ea = cmacs_dispatch_lisp_escape (action);
  if (name != NULL)
    {
      en = cmacs_dispatch_lisp_escape (name);
      expr = g_strdup_printf (
        "(cmacs-gowl-macro-record-command \"%s\" \"%s\" t)", ea, en);
    }
  else
    expr = g_strdup_printf (
      "(cmacs-gowl-macro-record-command \"%s\" nil t)", ea);
  return gowl_eval_raw (expr);
}

static McpToolResult *
handle_gowl_macro_voice_match (McpServer *s, const gchar *n,
                               JsonObject *a, gpointer u)
{
  const gchar *text;
  gboolean dry;
  g_autofree gchar *et = NULL, *expr = NULL;
  (void) s; (void) n; (void) u;

  text = json_object_get_string_member_with_default (a, "text", NULL);
  if (text == NULL || *text == '\0')
    return gowl_missing ("text");
  dry = json_object_get_boolean_member_with_default (a, "dry_run", FALSE);
  et = cmacs_dispatch_lisp_escape (text);
  expr = g_strdup_printf ("(cmacs-gowl-macro-voice-text \"%s\" %s)", et,
                          dry ? "t" : "nil");
  return gowl_eval_raw (expr);
}

static McpToolResult *
handle_gowl_macro_voice_status (McpServer *s, const gchar *n,
                                JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_eval_line ("cmacs-gowl-macro-command", "macro-voice status");
}

/* ── Input broadcasting (multiboxing) ──────────────────────────────
 *
 * Each tool is one `broadcast-' module command run through
 * `cmacs-gowl-broadcast-command' (cmacs-gowl-broadcast.el), which loads
 * the opt-in module when a command needs it and never signals: an error
 * comes back as "ERROR ..." text, turned into an MCP error here. */

static McpToolResult *
gowl_broadcast_line (const gchar *line)
{
  g_autofree gchar *el = cmacs_dispatch_lisp_escape (line);
  g_autofree gchar *expr = g_strdup_printf (
    "(progn (require 'cmacs-gowl-broadcast) "
    "(cmacs-gowl-broadcast-command \"%s\"))", el);
  GError *error = NULL;
  gchar *str = cmacs_dispatch_eval_string (expr, &error);
  McpToolResult *r;

  if (str != NULL && g_str_has_prefix (str, "ERROR"))
    {
      r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, str + (str[5] == ' ' ? 6 : 5));
      g_free (str);
      return r;
    }
  r = gowl_result (str, error);
  g_clear_error (&error);
  return r;
}

/* A name that goes on the command line: one word. */
static gboolean
gowl_broadcast_word (const gchar *w)
{
  const gchar *p;

  if (w == NULL || *w == '\0')
    return FALSE;
  for (p = w; *p != '\0'; p++)
    if (g_ascii_isspace (*p) || g_ascii_iscntrl (*p))
      return FALSE;
  return TRUE;
}

static McpToolResult *
handle_gowl_broadcast_status (McpServer *s, const gchar *n,
                              JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_broadcast_line ("broadcast-status");
}

static McpToolResult *
handle_gowl_broadcast_list (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_broadcast_line ("broadcast-list");
}

static McpToolResult *
handle_gowl_broadcast_set (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  static const gchar * const states[] = {
    "on", "off", "toggle", "panic", NULL
  };
  const gchar *state, *strict;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  strict = json_object_get_string_member_with_default (a, "strict", NULL);
  if (strict != NULL)
    {
      if (g_strcmp0 (strict, "on") != 0 && g_strcmp0 (strict, "off") != 0
          && g_strcmp0 (strict, "toggle") != 0)
        return gowl_missing ("strict (on, off or toggle)");
      line = g_strdup_printf ("broadcast-strict %s", strict);
      return gowl_broadcast_line (line);
    }
  state = json_object_get_string_member_with_default (a, "state", NULL);
  if (state == NULL || !g_strv_contains (states, state))
    return gowl_missing ("state (on, off, toggle or panic)");
  line = g_strdup_printf ("broadcast-%s", state);
  return gowl_broadcast_line (line);
}

/* broadcast-add-team / -add-rule from an object or one line of YAML */
static McpToolResult *
gowl_broadcast_define (JsonObject *a, const gchar *member,
                       const gchar *verb)
{
  g_autofree gchar *text = NULL;
  g_autofree gchar *line = NULL;
  const gchar *yaml;

  if (a != NULL && json_object_has_member (a, member))
    {
      JsonNode *node = json_object_get_member (a, member);
      g_autoptr (JsonGenerator) gen = json_generator_new ();

      if (!JSON_NODE_HOLDS_OBJECT (node))
        return gowl_missing (member);
      json_generator_set_root (gen, node);
      text = json_generator_to_data (gen, NULL);
    }
  else
    {
      yaml = json_object_get_string_member_with_default (a, "yaml", NULL);
      if (yaml == NULL || *yaml == '\0' || strchr (yaml, '\n') != NULL)
        return gowl_missing ("an object, or yaml (one line of flow YAML)");
      text = g_strdup (yaml);
    }
  line = g_strdup_printf ("%s %s", verb, text);
  return gowl_broadcast_line (line);
}

static McpToolResult *
handle_gowl_broadcast_add_team (McpServer *s, const gchar *n,
                                JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return gowl_broadcast_define (a, "team", "broadcast-add-team");
}

static McpToolResult *
handle_gowl_broadcast_add_rule (McpServer *s, const gchar *n,
                                JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return gowl_broadcast_define (a, "rule", "broadcast-add-rule");
}

static McpToolResult *
handle_gowl_broadcast_remove (McpServer *s, const gchar *n,
                              JsonObject *a, gpointer u)
{
  const gchar *kind, *name;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  kind = json_object_get_string_member_with_default (a, "kind", NULL);
  name = json_object_get_string_member_with_default (a, "name", NULL);
  if (g_strcmp0 (kind, "team") != 0 && g_strcmp0 (kind, "rule") != 0)
    return gowl_missing ("kind (team or rule)");
  if (!gowl_broadcast_word (name))
    return gowl_missing ("name");
  line = g_strdup_printf ("broadcast-remove-%s %s", kind, name);
  return gowl_broadcast_line (line);
}

static McpToolResult *
handle_gowl_broadcast_assign (McpServer *s, const gchar *n,
                              JsonObject *a, gpointer u)
{
  const gchar *team, *slot;
  gint64 id = -1;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  team = json_object_get_string_member_with_default (a, "team", NULL);
  slot = json_object_get_string_member_with_default (a, "slot", NULL);
  if (!gowl_broadcast_word (team) || !gowl_broadcast_word (slot))
    return gowl_missing ("team and slot");
  if (json_object_has_member (a, "client_id"))
    id = json_object_get_int_member (a, "client_id");
  if (id == 0)
    line = g_strdup_printf ("broadcast-unassign %s %s", team, slot);
  else if (id > 0)
    line = g_strdup_printf ("broadcast-assign %s %s %" G_GINT64_FORMAT,
                            team, slot, id);
  else
    line = g_strdup_printf ("broadcast-assign %s %s", team, slot);
  return gowl_broadcast_line (line);
}

static McpToolResult *
handle_gowl_broadcast_focus_slot (McpServer *s, const gchar *n,
                                  JsonObject *a, gpointer u)
{
  const gchar *team, *slot;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  team = json_object_get_string_member_with_default (a, "team", NULL);
  slot = json_object_get_string_member_with_default (a, "slot", NULL);
  if (!gowl_broadcast_word (slot))
    return gowl_missing ("slot");
  if (team != NULL && !gowl_broadcast_word (team))
    return gowl_missing ("team (one word)");
  line = team != NULL
    ? g_strdup_printf ("broadcast-focus-slot %s %s", team, slot)
    : g_strdup_printf ("broadcast-focus-slot %s", slot);
  return gowl_broadcast_line (line);
}

/* ── Hotkeys (AutoHotkey for gowl) ─────────────────────────────────
 *
 * Each tool is one `hotkey-' module command run through
 * `cmacs-gowl-hotkey-command' (cmacs-gowl-hotkey.el), which loads the
 * opt-in module and never signals: an error comes back as "ERROR ..."
 * text, turned into an MCP error here.  Ids, modes and names go on the
 * command line, so they are checked to be one word; free text (keys,
 * YAML) must be one line, since the command framing is a line. */

static McpToolResult *
gowl_hotkey_line (const gchar *line)
{
  g_autofree gchar *el = cmacs_dispatch_lisp_escape (line);
  g_autofree gchar *expr = g_strdup_printf (
    "(progn (require 'cmacs-gowl-hotkey) "
    "(cmacs-gowl-hotkey-command \"%s\"))", el);
  GError *error = NULL;
  gchar *str = cmacs_dispatch_eval_string (expr, &error);
  McpToolResult *r;

  if (str != NULL && g_str_has_prefix (str, "ERROR"))
    {
      r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, str + (str[5] == ' ' ? 6 : 5));
      g_free (str);
      return r;
    }
  r = gowl_result (str, error);
  g_clear_error (&error);
  return r;
}

/* Free text for the command line: present, and one line. */
static gboolean
gowl_hotkey_one_line (const gchar *t)
{
  return t != NULL && *t != '\0' && strpbrk (t, "\n\r") == NULL;
}

static McpToolResult *
handle_gowl_hotkey_status (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_hotkey_line ("hotkey-status");
}

static McpToolResult *
handle_gowl_hotkey_list (McpServer *s, const gchar *n,
                         JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_hotkey_line ("hotkey-list");
}

static McpToolResult *
handle_gowl_hotkey_history (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_hotkey_line ("hotkey-history");
}

/* hotkey-add from an object (a hotkey entry, or a section) or one line
   of flow YAML; `id' names it so it can be replaced and removed. */
static McpToolResult *
handle_gowl_hotkey_add (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  g_autofree gchar *text = NULL;
  g_autofree gchar *line = NULL;
  const gchar *yaml, *id;
  (void) s; (void) n; (void) u;

  if (a != NULL && json_object_has_member (a, "hotkey"))
    {
      JsonNode *node = json_object_get_member (a, "hotkey");
      g_autoptr (JsonGenerator) gen = json_generator_new ();

      if (!JSON_NODE_HOLDS_OBJECT (node))
        return gowl_missing ("hotkey (an object)");
      json_generator_set_root (gen, node);
      text = json_generator_to_data (gen, NULL);
    }
  else
    {
      yaml = json_object_get_string_member_with_default (a, "yaml", NULL);
      if (!gowl_hotkey_one_line (yaml))
        return gowl_missing ("a hotkey object, or yaml (one line of "
                             "flow YAML)");
      text = g_strdup (yaml);
    }
  id = json_object_get_string_member_with_default (a, "id", NULL);
  if (id != NULL && !gowl_broadcast_word (id))
    return gowl_missing ("id (one word)");
  line = id != NULL ? g_strdup_printf ("hotkey-add --id=%s %s", id, text)
                    : g_strdup_printf ("hotkey-add %s", text);
  return gowl_hotkey_line (line);
}

static McpToolResult *
handle_gowl_hotkey_remove (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  const gchar *id;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  id = json_object_get_string_member_with_default (a, "id", NULL);
  if (!gowl_broadcast_word (id))
    return gowl_missing ("id");
  line = g_strdup_printf ("hotkey-remove %s", id);
  return gowl_hotkey_line (line);
}

/* One of: a hotkey switched (id + enabled), suspending, or the mode. */
static McpToolResult *
handle_gowl_hotkey_set (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  static const gchar * const toggles[] = { "on", "off", "toggle", NULL };
  const gchar *id, *enabled, *suspended, *mode;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  id = json_object_get_string_member_with_default (a, "id", NULL);
  enabled = json_object_get_string_member_with_default (a, "enabled", NULL);
  suspended = json_object_get_string_member_with_default (a, "suspended",
                                                          NULL);
  mode = json_object_get_string_member_with_default (a, "mode", NULL);
  if (enabled != NULL)
    {
      if (!g_strv_contains (toggles, enabled))
        return gowl_missing ("enabled (on, off or toggle)");
      if (!gowl_broadcast_word (id))
        return gowl_missing ("id, with enabled");
      line = g_strdup_printf ("hotkey-%s %s",
                              g_strcmp0 (enabled, "on") == 0 ? "enable"
                              : g_strcmp0 (enabled, "off") == 0 ? "disable"
                              : "toggle", id);
    }
  else if (suspended != NULL)
    {
      if (!g_strv_contains (toggles, suspended))
        return gowl_missing ("suspended (on, off or toggle)");
      line = g_strdup_printf ("hotkey-suspend %s", suspended);
    }
  else if (mode != NULL)
    {
      if (!gowl_broadcast_word (mode))
        return gowl_missing ("mode (one word)");
      line = g_strdup_printf ("hotkey-mode %s", mode);
    }
  else
    return gowl_missing ("enabled (with id), suspended or mode");
  return gowl_hotkey_line (line);
}

static McpToolResult *
handle_gowl_hotkey_send (McpServer *s, const gchar *n,
                         JsonObject *a, gpointer u)
{
  const gchar *keys, *text;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  keys = json_object_get_string_member_with_default (a, "keys", NULL);
  text = json_object_get_string_member_with_default (a, "text", NULL);
  if (keys != NULL)
    {
      if (!gowl_hotkey_one_line (keys))
        return gowl_missing ("keys (one line; {Enter} for a newline)");
      line = g_strdup_printf ("hotkey-send %s", keys);
    }
  else
    {
      if (!gowl_hotkey_one_line (text))
        return gowl_missing ("keys or text (one line)");
      line = g_strdup_printf ("hotkey-send-text %s", text);
    }
  return gowl_hotkey_line (line);
}

static McpToolResult *
handle_gowl_hotkey_fire (McpServer *s, const gchar *n,
                         JsonObject *a, gpointer u)
{
  const gchar *id;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  id = json_object_get_string_member_with_default (a, "id", NULL);
  if (!gowl_broadcast_word (id))
    return gowl_missing ("id");
  line = g_strdup_printf ("hotkey-fire %s", id);
  return gowl_hotkey_line (line);
}

static gboolean
gowl_int_member (JsonObject *a, const gchar *name, gint64 *out)
{
  if (a == NULL || !json_object_has_member (a, name))
    return FALSE;
  *out = json_object_get_int_member (a, name);
  return TRUE;
}

static McpToolResult *
handle_gowl_screen_text (McpServer *s, const gchar *n,
                         JsonObject *a, gpointer u)
{
  gint64 x, y, w, h;
  const gchar *lang;
  gboolean copy;
  g_autofree gchar *el = NULL, *expr = NULL;
  (void) s; (void) n; (void) u;

  if (!gowl_int_member (a, "x", &x) || !gowl_int_member (a, "y", &y)
      || !gowl_int_member (a, "width", &w)
      || !gowl_int_member (a, "height", &h))
    return gowl_missing ("x, y, width, height");
  lang = json_object_get_string_member_with_default (a, "language", NULL);
  copy = json_object_get_boolean_member_with_default (a, "copy", FALSE);
  if (lang != NULL && *lang != '\0')
    {
      el = cmacs_dispatch_lisp_escape (lang);
      expr = g_strdup_printf (
        "(cmacs-gowl-screen-text %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
        " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " \"%s\" %s)",
        x, y, w, h, el, copy ? "t" : "nil");
    }
  else
    expr = g_strdup_printf (
      "(cmacs-gowl-screen-text %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
      " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " nil %s)",
      x, y, w, h, copy ? "t" : "nil");
  return gowl_eval_raw (expr);
}

static McpToolResult *
handle_gowl_pick_color (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  gint64 x, y;
  g_autofree gchar *expr = NULL;
  (void) s; (void) n; (void) u;

  if (!gowl_int_member (a, "x", &x) || !gowl_int_member (a, "y", &y))
    return gowl_missing ("x, y");
  expr = g_strdup_printf ("(cmacs-gowl-pixel-color %" G_GINT64_FORMAT
                          " %" G_GINT64_FORMAT ")", x, y);
  return gowl_eval_raw (expr);
}

static McpToolResult *
handle_gowl_clipboard_list (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return gowl_eval_line ("cmacs-gowl-command", "clipboard-list");
}

static McpToolResult *
gowl_clipboard_by_id (JsonObject *a, const gchar *word)
{
  gint64 id;
  g_autofree gchar *line = NULL;

  if (!gowl_int_member (a, "id", &id) || id <= 0)
    return gowl_missing ("id (a positive entry id)");
  line = g_strdup_printf ("%s %" G_GINT64_FORMAT, word, id);
  return gowl_eval_line ("cmacs-gowl-command", line);
}

static McpToolResult *
handle_gowl_clipboard_entry (McpServer *s, const gchar *n,
                             JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return gowl_clipboard_by_id (a, "clipboard-path");
}

static McpToolResult *
handle_gowl_clipboard_copy (McpServer *s, const gchar *n,
                            JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return gowl_clipboard_by_id (a, "clipboard-copy");
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

  /* ── Macros, the recorder, voice, the screen, the clipboard ── */
  {
    static const struct {
      const gchar   *name;
      gboolean       read_only;
      const gchar   *schema;
      McpToolHandler handler;
      const gchar   *description;
    } tools[] = {
      { "gowl_macro_run", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"name\":{\"type\":\"string\",\"description\":\"A macro name "
        "(a file on the macro path, a registered or an Elisp macro), or "
        "a path to a .c file\"},"
        "\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},"
        "\"required\":[\"name\"]}",
        handle_gowl_macro_run,
        "Run a gowl macro: in-process C (crispy) or an Elisp macro that "
        "drives the compositor. Runs under gowl's fault guard and time "
        "budget; a crash or runaway loop is stopped and held back. "
        "Loads the opt-in macro module on first use." },
      { "gowl_macro_list", TRUE, "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_macro_list,
        "Every macro runnable by name, as JSON: name, kind (file, "
        "registered, custom = Elisp, ...), path, held-back." },
      { "gowl_broadcast_status", TRUE,
        "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_broadcast_status,
        "Input broadcasting (multiboxing): whether it is on, strict mode, "
        "the toggle and panic keys, every team with the window in each "
        "slot, every rule with the reason it cannot run if any, and "
        "delivery counters (JSON). The module is opt-in." },
      { "gowl_broadcast_list", TRUE,
        "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_broadcast_list,
        "The broadcast teams and rules in force, each as YAML (JSON)." },
      { "gowl_broadcast_set", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"state\":{\"type\":\"string\",\"enum\":[\"on\",\"off\","
        "\"toggle\",\"panic\"]},"
        "\"strict\":{\"type\":\"string\",\"enum\":[\"on\",\"off\","
        "\"toggle\"]}}}",
        handle_gowl_broadcast_set,
        "Switch input broadcasting on, off or toggle it (a toast shows the "
        "result), or panic: off, and every key held in any window "
        "released. Or set strict one-press-one-window mode instead." },
      { "gowl_broadcast_add_team", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"team\":{\"type\":\"object\",\"description\":\"{name, "
        "slots: [{name, match, focus-key, delivery}], groups: {NAME: "
        "[slot]}}; match is a filter such as app-id = eqgame.exe\"},"
        "\"yaml\":{\"type\":\"string\"}}}",
        handle_gowl_broadcast_add_team,
        "Add, or replace by name, a broadcast team for this session." },
      { "gowl_broadcast_add_rule", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"rule\":{\"type\":\"object\",\"description\":\"{name, "
        "team, when, keys: {include, exclude}, modifiers, targets, "
        "translate, mode, reset-ms, delivery, mouse, delay-ms, local}\"},"
        "\"yaml\":{\"type\":\"string\"}}}",
        handle_gowl_broadcast_add_rule,
        "Add, or replace by name, a broadcast rule for this session; the "
        "reply says when it cannot run." },
      { "gowl_broadcast_remove", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"kind\":{\"type\":\"string\",\"enum\":[\"team\",\"rule\"]},"
        "\"name\":{\"type\":\"string\"}},\"required\":[\"kind\","
        "\"name\"]}",
        handle_gowl_broadcast_remove, "Remove a broadcast team or rule." },
      { "gowl_broadcast_assign", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"team\":{\"type\":\"string\"},\"slot\":{\"type\":\"string\"},"
        "\"client_id\":{\"type\":\"integer\",\"description\":\"The "
        "window (default: the focused one); 0 hands the slot back to its "
        "match\"}},\"required\":[\"team\",\"slot\"]}",
        handle_gowl_broadcast_assign,
        "Put a window in a broadcast team's slot by hand." },
      { "gowl_broadcast_focus_slot", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"team\":{\"type\":\"string\"},\"slot\":{\"type\":\"string\"}},"
        "\"required\":[\"slot\"]}",
        handle_gowl_broadcast_focus_slot,
        "Focus the window in a broadcast team's slot, viewing its tag." },
      { "gowl_hotkey_status", TRUE,
        "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_hotkey_status,
        "Hotkeys (AutoHotkey for gowl): whether they are suspended, the "
        "key mode, counts of hotkeys, remaps, timers and hotstrings, the "
        "lock keys, the last hotkey fired and the last error (JSON). The "
        "module is opt-in; this loads it." },
      { "gowl_hotkey_list", TRUE,
        "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_hotkey_list,
        "Every hotkey and remap in force (JSON): id, key as written and "
        "canonical, context, mode, enabled, origin, description." },
      { "gowl_hotkey_history", TRUE,
        "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_hotkey_history,
        "The last 64 inputs the hotkey module saw (JSON): keycode, keysym, "
        "pressed, injected, swallowed and the hotkey each fired. The "
        "first thing to look at when a hotkey does not fire." },
      { "gowl_hotkey_add", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"hotkey\":{\"type\":\"object\",\"description\":\"A hotkey "
        "entry {id, key, do, context, when, mode, double, hold, ...} -- "
        "key in AutoHotkey notation (#!t, CapsLock & j, ~LButton) or gowl's "
        "(Super+Alt+t); do is a list of actions such as {shell: CMD}, "
        "{send: KEYS}, {action: spawn, arg: PROGRAM} -- or a whole section "
        "{hotkeys: [...], remaps: {...}, modes: {...}}\"},"
        "\"yaml\":{\"type\":\"string\",\"description\":\"The same as "
        "one line of flow YAML\"},"
        "\"id\":{\"type\":\"string\",\"description\":\"Name it, so "
        "adding again replaces it and gowl_hotkey_remove takes it back\"}}}",
        handle_gowl_hotkey_add,
        "Add a hotkey (or a section of them) for this session; refused "
        "whole, with the reason, on any problem." },
      { "gowl_hotkey_remove", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
        handle_gowl_hotkey_remove,
        "Remove a hotkey added at run time (one from the configuration is "
        "disabled instead)." },
      { "gowl_hotkey_set", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"id\":{\"type\":\"string\"},"
        "\"enabled\":{\"type\":\"string\",\"enum\":[\"on\",\"off\","
        "\"toggle\"]},"
        "\"suspended\":{\"type\":\"string\",\"enum\":[\"on\",\"off\","
        "\"toggle\"]},"
        "\"mode\":{\"type\":\"string\",\"description\":\"A key mode; "
        "default leaves every mode\"}}}",
        handle_gowl_hotkey_set,
        "Switch one hotkey on or off (id + enabled), suspend every hotkey, "
        "or enter a key mode." },
      { "gowl_hotkey_send", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"keys\":{\"type\":\"string\",\"description\":\"AutoHotkey "
        "Send syntax: ^c, {Enter}, {Tab 3}, {Shift down}\"},"
        "\"text\":{\"type\":\"string\",\"description\":\"Literal "
        "text instead\"}}}",
        handle_gowl_hotkey_send,
        "Type keys or text into the focused window through the hotkey "
        "module." },
      { "gowl_hotkey_fire", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
        handle_gowl_hotkey_fire,
        "Run a hotkey's actions as if it had been pressed." },
      { "gowl_macro_status", TRUE, "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_macro_status,
        "Running macros, held-back ones and why, the fault count, the "
        "time budget, triggers -- the macro module's status JSON." },
      { "gowl_macro_stop", FALSE,
        "{\"type\":\"object\",\"properties\":{\"which\":{\"type\":"
        "\"string\",\"description\":\"A macro name, a run id or all "
        "(the default)\"}}}",
        handle_gowl_macro_stop, "Stop running macros." },
      { "gowl_macro_record", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"action\":{\"type\":\"string\",\"enum\":[\"start\",\"stop\","
        "\"cancel\",\"status\"]},"
        "\"name\":{\"type\":\"string\",\"description\":\"With start: "
        "also write NAME.c\"}},\"required\":[\"action\"]}",
        handle_gowl_macro_record,
        "The macro recorder (Super+Alt+r). start records the person's "
        "keys, clicks, drags and scrolls; stop writes last-recording.c "
        "(and NAME.c) and replies `recorded NAME STEPS PATH'; cancel "
        "discards; status reports. Starting from here needs gowl's "
        "`input-recording' consent, because it watches the person's "
        "input; the screen is framed while it runs and password prompts "
        "are not recorded." },
      { "gowl_macro_voice_match", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"text\":{\"type\":\"string\"},\"dry_run\":{\"type\":\"boolean\"}},"
        "\"required\":[\"text\"]}",
        handle_gowl_macro_voice_match,
        "Run the macro a sentence names, as Super+Alt+m does with what "
        "was said: a configured phrase, a macro's name said as words "
        "(\"pip corner 25\" runs pip-corner 25), or every word of a name. "
        "dry_run reports what it would run (heard, normalised, macro, "
        "args) and runs nothing." },
      { "gowl_macro_voice_status", TRUE,
        "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_macro_voice_status,
        "The voice listener's state: listening, command, time limit, last "
        "sentence heard, last error. There is no tool to start "
        "listening: the microphone is the person's to turn on." },
      { "gowl_screen_text", FALSE,
        "{\"type\":\"object\",\"properties\":{"
        "\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"},"
        "\"width\":{\"type\":\"integer\"},\"height\":{\"type\":\"integer\"},"
        "\"language\":{\"type\":\"string\",\"description\":\"tesseract "
        "languages, e.g. eng+deu (default: the screenshot module's)\"},"
        "\"copy\":{\"type\":\"boolean\",\"description\":\"Also put the "
        "text on the clipboard (default false)\"}},"
        "\"required\":[\"x\",\"y\",\"width\",\"height\"]}",
        handle_gowl_screen_text,
        "Read the text in a region of the screen (OCR via tesseract, the "
        "screenshot module's ocr-command), in layout coordinates as "
        "gowl_list_monitors and gowl_list_clients report them. Returns "
        "the text, \"\" when there is none. The clipboard is left alone "
        "unless copy is true." },
      { "gowl_pick_color", TRUE,
        "{\"type\":\"object\",\"properties\":{"
        "\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"}},"
        "\"required\":[\"x\",\"y\"]}",
        handle_gowl_pick_color,
        "The colour of the screen at layout x, y, as \"#rrggbb\". The "
        "clipboard is left alone." },
      { "gowl_clipboard_list", TRUE, "{\"type\":\"object\",\"properties\":{}}",
        handle_gowl_clipboard_list,
        "The clipboard history, newest first: one line per entry, "
        "ID<TAB>MIME<TAB>BYTES<TAB>PREVIEW. This is everything the person "
        "copied -- passwords included -- so read it when the task needs "
        "it, not by habit. The Super+space menu keeps it private for the "
        "same reason." },
      { "gowl_clipboard_entry", TRUE,
        "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},"
        "\"required\":[\"id\"]}",
        handle_gowl_clipboard_entry,
        "The path of one history entry's stored bytes (exactly what was "
        "copied, in its MIME type)." },
      { "gowl_clipboard_copy", FALSE,
        "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},"
        "\"required\":[\"id\"]}",
        handle_gowl_clipboard_copy,
        "Put a history entry back on the clipboard: the next paste in any "
        "window produces it. Replaces what the person has copied." },
    };
    gsize i;

    for (i = 0; i < G_N_ELEMENTS (tools); i++)
      {
        tool = mcp_tool_new (tools[i].name, tools[i].description);
        schema = cmacs_mcp_schema_from_string (tools[i].schema);
        mcp_tool_set_input_schema (tool, schema);
        mcp_tool_set_read_only_hint (tool, tools[i].read_only);
        mcp_server_add_tool (server, tool, tools[i].handler, NULL, NULL);
        g_object_unref (tool);
      }
  }
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GOWL */
