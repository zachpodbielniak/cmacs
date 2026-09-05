/*
 * cmacs-mcp-tools-vidstudio.c — Reel video editor MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools over the handle-based `cmacs-vidstudio-*' model DEFUNs
 * (tracks / clips / transitions / effects / render / export).  Everything is
 * CPU + headless, so an agent can cut a video with no display.  The MCP
 * `eval' tool already reaches every DEFUN; these add typed schemas.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_VIDSTUDIO)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Render STR as an Elisp string literal, or `nil' when NULL.  Caller frees. */
static gchar *
vs_lisp_str (const gchar *str)
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

/* Run ELISP and return its value (or the error) as the tool result.  Takes
 * ownership of ELISP. */
static McpToolResult *
vs_eval_result (gchar *elisp)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *src = elisp;
  g_autofree gchar *out = cmacs_dispatch_eval (src, &error);
  McpToolResult *result = mcp_tool_result_new (out == NULL);
  mcp_tool_result_add_text (result,
    out ? out : (error ? error->message : "error"));
  return result;
}

static gint64
vs_int (JsonObject *a, const gchar *k, gint64 dflt)
{
  return json_object_has_member (a, k)
    ? json_object_get_int_member (a, k) : dflt;
}

static McpToolResult *
handle_new (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  double fps = json_object_has_member (a, "fps")
    ? json_object_get_double_member (a, "fps") : 30.0;
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(format \"handle %%d\" (cmacs-vidstudio-new %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT " %g))",
     vs_int (a, "width", 1280), vs_int (a, "height", 720), fps));
}

static McpToolResult *
handle_info (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(let* ((h %" G_GINT64_FORMAT ") (nt (cmacs-vidstudio-n-tracks h))"
     " (lines '()))"
     " (dotimes (tr nt)"
     "  (let ((cells '()))"
     "   (dotimes (ci (cmacs-vidstudio-track-clip-count h tr))"
     "    (let ((id (cmacs-vidstudio-clip-at h tr ci)))"
     "     (push (format \"[#%%d %%d+%%d%%s]\" id"
     "       (cmacs-vidstudio-clip-start-frame h id)"
     "       (cmacs-vidstudio-clip-duration h id)"
     "       (if (cmacs-vidstudio-clip-ready-p h id) \"\" \" decoding\"))"
     "      cells)))"
     "   (push (format \"track %%d: %%s\" tr"
     "     (string-join (nreverse cells) \" \")) lines)))"
     " (format \"%%dx%%d @%%gfps total %%d frames | %%s\""
     "  (cmacs-vidstudio-width h) (cmacs-vidstudio-height h)"
     "  (cmacs-vidstudio-fps h) (cmacs-vidstudio-total-frames h)"
     "  (string-join (nreverse lines) \" || \")))",
     vs_int (a, "handle", 0)));
}

static McpToolResult *
handle_add_track (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(format \"track %%d\" (cmacs-vidstudio-add-track %" G_GINT64_FORMAT
     "))", vs_int (a, "handle", 0)));
}

static McpToolResult *
handle_add_clip (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *kind = json_object_get_string_member_with_default (a, "kind", NULL);
  gint64 h = vs_int (a, "handle", 0);
  gint64 track = vs_int (a, "track", 0);
  gint64 dur = vs_int (a, "duration_frames", 90);
  gint64 r = vs_int (a, "r", 128), g = vs_int (a, "g", 128);
  gint64 b = vs_int (a, "b", 128);
  gchar *elisp = NULL;
  (void) s; (void) n; (void) u;

  if (g_strcmp0 (kind, "video") == 0 || g_strcmp0 (kind, "image") == 0)
    {
      g_autofree gchar *path =
        vs_lisp_str (json_object_get_string_member_with_default (a, "path", NULL));
      elisp = g_strdup_printf
        ("(format \"clip %%d\" (cmacs-vidstudio-add-%s-clip"
         " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %s %" G_GINT64_FORMAT
         "))", kind, h, track, path, dur);
    }
  else if (g_strcmp0 (kind, "solid") == 0)
    elisp = g_strdup_printf
      ("(format \"clip %%d\" (cmacs-vidstudio-add-solid-clip"
       " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " 255))", h, track, dur, r, g, b);
  else if (g_strcmp0 (kind, "text") == 0)
    {
      g_autofree gchar *text =
        vs_lisp_str (json_object_get_string_member_with_default (a, "text", NULL));
      elisp = g_strdup_printf
        ("(format \"clip %%d\" (cmacs-vidstudio-add-text-clip"
         " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %s %" G_GINT64_FORMAT
         " 255 255 255 255))", h, track, text, dur);
    }
  else
    {
      McpToolResult *res = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (res, "kind must be video|image|solid|text");
      return res;
    }
  return vs_eval_result (elisp);
}

static McpToolResult *
handle_transition (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(progn (cmacs-vidstudio-set-transition %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
     " 0) \"ok\")",
     vs_int (a, "handle", 0), vs_int (a, "clip", 0),
     vs_int (a, "type", 1), vs_int (a, "overlap_frames", 15)));
}

static McpToolResult *
handle_effect (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(progn (cmacs-vidstudio-add-effect %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT ") \"ok\")",
     vs_int (a, "handle", 0), vs_int (a, "clip", 0), vs_int (a, "type", 3)));
}

static McpToolResult *
handle_split (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(format \"tail clip %%S\" (cmacs-vidstudio-split-clip"
     " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT "))",
     vs_int (a, "handle", 0), vs_int (a, "clip", 0),
     vs_int (a, "at_frame", 0)));
}

static McpToolResult *
handle_render_frame (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *path =
    vs_lisp_str (json_object_get_string_member_with_default (a, "path", NULL));
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(let ((png (cmacs-vidstudio-render-png %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT ")) (coding-system-for-write 'binary))"
     " (write-region png nil %s nil 'silent)"
     " (format \"wrote %%d bytes\" (length png)))",
     vs_int (a, "handle", 0), vs_int (a, "frame", 0), path));
}

static McpToolResult *
handle_export (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *format = json_object_has_member (a, "format")
    ? json_object_get_string_member_with_default (a, "format", NULL) : "mp4";
  g_autofree gchar *path =
    vs_lisp_str (json_object_get_string_member_with_default (a, "path", NULL));
  (void) s; (void) n; (void) u;
  if (g_strcmp0 (format, "gif") == 0)
    return vs_eval_result (g_strdup_printf
      ("(progn (cmacs-vidstudio-export-gif %" G_GINT64_FORMAT
       " %s) \"exported\")", vs_int (a, "handle", 0), path));
  return vs_eval_result (g_strdup_printf
    ("(progn (cmacs-vidstudio-export-video %" G_GINT64_FORMAT
     " %s 0) \"exported\")", vs_int (a, "handle", 0), path));
}

static void
vs_add (McpServer *server, const gchar *name, const gchar *desc,
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

static McpToolResult *
handle_add_keyframe (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gint64 h = vs_int (a, "handle", 0), cid = vs_int (a, "clip_id", 0);
  gint64 param = vs_int (a, "param", 0), easing = vs_int (a, "easing", 0);
  gdouble frame = json_object_has_member (a, "frame")
    ? json_object_get_double_member (a, "frame") : 0.0;
  gdouble value = json_object_has_member (a, "value")
    ? json_object_get_double_member (a, "value") : 0.0;
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(cmacs-vidstudio-add-keyframe %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT " %g %g %" G_GINT64_FORMAT ")",
     h, cid, param, frame, value, easing));
}

static McpToolResult *
handle_add_audio (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gint64 h = vs_int (a, "handle", 0), from = vs_int (a, "from_frame", 0);
  const gchar *path = json_object_get_string_member_with_default (a, "path", NULL);
  gdouble vol = json_object_has_member (a, "volume")
    ? json_object_get_double_member (a, "volume") : 1.0;
  g_autofree gchar *epath = cmacs_dispatch_lisp_escape (path ? path : "");
  (void) s; (void) n; (void) u;
  return vs_eval_result (g_strdup_printf
    ("(cmacs-vidstudio-add-audio-file %" G_GINT64_FORMAT " \"%s\" %"
     G_GINT64_FORMAT " %g)", h, epath, from, vol));
}

void
cmacs_mcp_tools_vidstudio_register (McpServer *server)
{
  vs_add (server, "vidstudio_new",
    "Create a WIDTHxHEIGHT video project at FPS; returns its handle.",
    "{\"type\":\"object\",\"properties\":{"
    "\"width\":{\"type\":\"integer\"},\"height\":{\"type\":\"integer\"},"
    "\"fps\":{\"type\":\"number\"}},\"required\":[\"width\",\"height\"]}",
    FALSE, handle_new);

  vs_add (server, "vidstudio_info",
    "Describe the project: size, fps, total frames, per-track clip layout.",
    "{\"type\":\"object\",\"properties\":{\"handle\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\"]}", TRUE, handle_info);

  vs_add (server, "vidstudio_add_track",
    "Append a track (composites above lower tracks); returns its index.",
    "{\"type\":\"object\",\"properties\":{\"handle\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\"]}", FALSE, handle_add_track);

  vs_add (server, "vidstudio_add_clip",
    "Append a clip to TRACK.  KIND: video|image (PATH), solid (R G B), "
    "text (TEXT).  DURATION_FRAMES at project fps.  Video clips decode on "
    "a worker thread (see vidstudio_info's 'decoding' marker).",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"track\":{\"type\":\"integer\"},"
    "\"kind\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},"
    "\"text\":{\"type\":\"string\"},\"duration_frames\":{\"type\":\"integer\"},"
    "\"r\":{\"type\":\"integer\"},\"g\":{\"type\":\"integer\"},"
    "\"b\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\",\"track\",\"kind\"]}", FALSE, handle_add_clip);

  vs_add (server, "vidstudio_set_transition",
    "Set CLIP's leading transition.  TYPE: 0 fade,1 dissolve,2 wipe,"
    "3 slide,4 zoom,5 iris,6 flip,7 push,8 clock-wipe; -1 removes.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"clip\":{\"type\":\"integer\"},"
    "\"type\":{\"type\":\"integer\"},"
    "\"overlap_frames\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\",\"clip\",\"type\"]}", FALSE, handle_transition);

  vs_add (server, "vidstudio_add_effect",
    "Append an effect to CLIP.  TYPE: 0 blur,1 bloom,2 color-grade,"
    "3 vignette,4 grain.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"clip\":{\"type\":\"integer\"},"
    "\"type\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\",\"clip\",\"type\"]}", FALSE, handle_effect);

  vs_add (server, "vidstudio_add_keyframe",
    "Add a keyframe on CLIP_ID: PARAM (0 opacity,1 x,2 y,3 scale,4 rotation) "
    "at FRAME (clip-relative) = VALUE, optional EASING.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"clip_id\":{\"type\":\"integer\"},"
    "\"param\":{\"type\":\"integer\"},\"frame\":{\"type\":\"number\"},"
    "\"value\":{\"type\":\"number\"},\"easing\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\",\"clip_id\",\"param\",\"frame\",\"value\"]}",
    FALSE, handle_add_keyframe);

  vs_add (server, "vidstudio_add_audio",
    "Add an audio file to the lane at FROM_FRAME with VOLUME.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"path\":{\"type\":\"string\"},"
    "\"from_frame\":{\"type\":\"integer\"},\"volume\":{\"type\":\"number\"}},"
    "\"required\":[\"handle\",\"path\"]}",
    FALSE, handle_add_audio);

  vs_add (server, "vidstudio_split",
    "Split CLIP at AT_FRAME (relative to the clip start).",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"clip\":{\"type\":\"integer\"},"
    "\"at_frame\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\",\"clip\",\"at_frame\"]}", FALSE, handle_split);

  vs_add (server, "vidstudio_render_frame",
    "Composite FRAME and write it to PATH as PNG (agent-viewable preview).",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"frame\":{\"type\":\"integer\"},"
    "\"path\":{\"type\":\"string\"}},"
    "\"required\":[\"handle\",\"frame\",\"path\"]}",
    FALSE, handle_render_frame);

  vs_add (server, "vidstudio_export",
    "Export the timeline.  FORMAT mp4 (H.264) or gif.  Waits for any "
    "in-flight clip decodes, so output always has real frames.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"path\":{\"type\":\"string\"},"
    "\"format\":{\"type\":\"string\"}},"
    "\"required\":[\"handle\",\"path\"]}", FALSE, handle_export);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_VIDSTUDIO */
