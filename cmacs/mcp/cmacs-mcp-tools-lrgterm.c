/*
 * cmacs-mcp-tools-lrgterm.c — MCP tools for the output_lrg display backend
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Read-mostly MCP tools that let an agent introspect and snapshot the
 * independent libregnum/raylib display backend (output_lrg).  They dispatch
 * small Elisp snippets via cmacs_dispatch_eval; lrgterm_dump_screen drives
 * the `lrg-capture-screen' DEFUN to attach a live PNG of the lrg frame, so an
 * agent can SEE what the backend is rendering.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_LRGTERM)

#include <glib.h>
#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Elisp that binds `f' to the first live output_lrg frame, then runs BODY,
   or yields ERRMSG when no lrg frame exists.  Takes ownership of BODY.  */
static gchar *
lt_with_frame (gchar *body)
{
  gchar *out = g_strdup_printf
    ("(let ((f (catch 'lrgf (dolist (fr (frame-list))"
     " (when (eq (framep fr) 'lrg) (throw 'lrgf fr))))))"
     " (if f (progn %s) \"No lrg frame (start Emacs with --lrg)\"))",
     body);
  g_free (body);
  return out;
}

/* Run ELISP, return its value (or error) as a text result.  Owns ELISP.  */
static McpToolResult *
lt_eval_result (gchar *elisp)
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
handle_frame_info (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(format \"size=%dx%d px  %dx%d chars  col=%d line=%d  font=%S  monitor=%S\""
     " (frame-pixel-width f) (frame-pixel-height f)"
     " (frame-width f) (frame-height f)"
     " (frame-char-width f) (frame-char-height f)"
     " (frame-parameter f 'font) (lrg-display-pixel-size))")));
}

static McpToolResult *
handle_render_stats (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(format \"frames=%d  visible=%S  focus=%S  display-cells=%d  visual=%S\""
     " (length (frame-list)) (frame-visible-p f)"
     " (eq f (selected-frame)) (display-color-cells f)"
     " (display-visual-class f))")));
}

static McpToolResult *
handle_force_redraw (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(progn (redraw-frame f) (redisplay t) \"redrawn\")")));
}

static McpToolResult *
handle_dump_screen (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *path = g_build_filename (g_get_tmp_dir (),
                                             "cmacs-lrgterm-dump.png", NULL);
  g_autoptr (GError) error = NULL;
  g_autofree gchar *elisp = lt_with_frame (g_strdup_printf
    ("(progn (redisplay t) (lrg-capture-screen \"%s\" f) \"ok\")", path));
  g_autofree gchar *out = cmacs_dispatch_eval (elisp, &error);
  McpToolResult *result;

  (void) s; (void) n; (void) a; (void) u;
  if (out == NULL || g_strcmp0 (out, "ok") != 0
      || !g_file_test (path, G_FILE_TEST_EXISTS))
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        out ? out : (error ? error->message : "capture failed"));
      return result;
    }
  result = mcp_tool_result_new (FALSE);
  mcp_tool_result_add_text (result, "lrg frame snapshot:");
  cmacs_mcp_result_add_png_file (result, path);
  return result;
}

static McpToolResult *
handle_3d_state (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(format \"render-mode=%S arrangement=%S environment=%S\""
     " (cmacs-lrg-render-mode f) (cmacs-lrg-3d-arrangement f)"
     " (cmacs-lrg-3d-environment f))")));
}

static McpToolResult *
handle_3d_cycle_arrangement (McpServer *s, const gchar *n, JsonObject *a,
                             gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(let* ((all '(\"single-panel\" \"per-window\" \"free\"))"
     " (cur (cmacs-lrg-3d-arrangement f))"
     " (nxt (or (cadr (member cur all)) (car all))))"
     " (if (cmacs-lrg-3d-set-arrangement nxt f)"
     " (format \"arrangement -> %s\" nxt) \"not a 3D lrg frame\"))")));
}

static McpToolResult *
handle_3d_cycle_environment (McpServer *s, const gchar *n, JsonObject *a,
                             gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(let* ((all '(\"void\" \"workshop\" \"cockpit\"))"
     " (cur (cmacs-lrg-3d-environment f))"
     " (nxt (or (cadr (member cur all)) (car all))))"
     " (if (cmacs-lrg-3d-set-environment nxt f)"
     " (format \"environment -> %s\" nxt) \"not a 3D lrg frame\"))")));
}

static McpToolResult *
handle_3d_camera_orbit (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(if (cmacs-lrg-3d-camera \"orbit-left\" 20 f)"
     " \"orbited\" \"not a 3D lrg frame\")")));
}

static McpToolResult *
handle_3d_focus_selected (McpServer *s, const gchar *n, JsonObject *a,
                          gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(if (cmacs-lrg-3d-focus-panel (frame-selected-window f) f)"
     " \"focused the selected window front-and-centre\""
     " \"not a 3D lrg frame\")")));
}

static McpToolResult *
handle_3d_pin_selected (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(if (cmacs-lrg-3d-pin-panel (frame-selected-window f) f)"
     " \"pinned the selected window's panel in place\""
     " \"not a 3D lrg frame\")")));
}

static McpToolResult *
handle_3d_unpin_all (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lt_eval_result (lt_with_frame (g_strdup
    ("(if (cmacs-lrg-3d-unpin-panel t f)"
     " \"released all panels back to automatic layout\""
     " \"not a 3D lrg frame\")")));
}

/* Register an MCP tool (mirrors the helper in the other tool files).  */
static void
lt_add (McpServer *server, const gchar *name, const gchar *desc,
        gboolean read_only,
        McpToolResult *(*handler) (McpServer *, const gchar *,
                                   JsonObject *, gpointer))
{
  McpTool *tool = mcp_tool_new (name, desc);
  if (read_only)
    mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handler, NULL, NULL);
  g_object_unref (tool);
}

void
cmacs_mcp_tools_lrgterm_register (McpServer *server)
{
  lt_add (server, "lrgterm_frame_info",
    "Report the output_lrg frame's pixel/char size, font and monitor.",
    TRUE, handle_frame_info);
  lt_add (server, "lrgterm_render_stats",
    "Report lrg display stats (frame count, visibility, focus, colour depth).",
    TRUE, handle_render_stats);
  lt_add (server, "lrgterm_force_redraw",
    "Force a full redraw + present of the lrg frame.",
    FALSE, handle_force_redraw);
  lt_add (server, "lrgterm_dump_screen",
    "Capture the lrg frame to a PNG and return it as an image, so you can see "
    "exactly what the libregnum/raylib backend is rendering.",
    TRUE, handle_dump_screen);
  lt_add (server, "lrgterm_3d_state",
    "Report the lrg 3D render mode, panel arrangement and ambient environment.",
    TRUE, handle_3d_state);
  lt_add (server, "lrgterm_3d_cycle_arrangement",
    "Cycle the 3D panel arrangement (single-panel -> per-window -> free).",
    FALSE, handle_3d_cycle_arrangement);
  lt_add (server, "lrgterm_3d_cycle_environment",
    "Cycle the 3D ambient environment (void -> workshop -> cockpit).",
    FALSE, handle_3d_cycle_environment);
  lt_add (server, "lrgterm_3d_camera_orbit",
    "Orbit the 3D camera around the panels (use lrgterm_dump_screen to see it).",
    FALSE, handle_3d_camera_orbit);
  lt_add (server, "lrgterm_3d_focus_selected",
    "Bring the selected window's 3D panel front-and-centre (fly the camera to "
    "it and focus it; others recede). The 'command-the-room' gesture.",
    FALSE, handle_3d_focus_selected);
  lt_add (server, "lrgterm_3d_pin_selected",
    "Pin the selected window's 3D panel in place so the arrangement no longer "
    "moves it.",
    FALSE, handle_3d_pin_selected);
  lt_add (server, "lrgterm_3d_unpin_all",
    "Release all manually-placed 3D panels back to automatic layout.",
    FALSE, handle_3d_unpin_all);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_LRGTERM */
