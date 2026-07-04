/*
 * cmacs-mcp-tools-imgedit.c — 2D image / sprite editor MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools over the handle-based `cmacs-imgedit-*' model DEFUNs.
 * The model is pure CPU and headless, so an agent can compose sprites or
 * annotate screenshots with no display at all.  The MCP `eval' tool already
 * reaches every DEFUN; these add typed schemas for the common operations.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_IMGEDIT)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Render STR as an Elisp string literal, or `nil' when NULL.  Caller frees. */
static gchar *
ie_lisp_str (const gchar *str)
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
ie_eval_result (gchar *elisp)
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
ie_int (JsonObject *a, const gchar *k, gint64 dflt)
{
  return json_object_has_member (a, k)
    ? json_object_get_int_member (a, k) : dflt;
}

static McpToolResult *
handle_new (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(format \"handle %%d\" (cmacs-imgedit-new %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT "))",
     ie_int (a, "width", 64), ie_int (a, "height", 64)));
}

static McpToolResult *
handle_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *path =
    ie_lisp_str (json_object_get_string_member (a, "path"));
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(let ((h (cmacs-imgedit-open %s)))"
     " (format \"handle %%d (%%dx%%d)\" h (cmacs-imgedit-width h)"
     " (cmacs-imgedit-height h)))", path));
}

static McpToolResult *
handle_save (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *path =
    ie_lisp_str (json_object_get_string_member (a, "path"));
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(progn (cmacs-imgedit-save %" G_GINT64_FORMAT " %s) \"saved\")",
     ie_int (a, "handle", 0), path));
}

static McpToolResult *
handle_info (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(let* ((h %" G_GINT64_FORMAT ") (nl (cmacs-imgedit-n-layers h)) (out '()))"
     " (dotimes (i nl)"
     "  (push (format \"%%d:%%s%%s o=%%.2f\" i (cmacs-imgedit-layer-name h i)"
     "   (if (cmacs-imgedit-layer-visible-p h i) \"\" \" hidden\")"
     "   (cmacs-imgedit-layer-opacity h i)) out))"
     " (format \"%%dx%%d active=%%d layers: %%s\" (cmacs-imgedit-width h)"
     "  (cmacs-imgedit-height h) (cmacs-imgedit-active-layer h)"
     "  (string-join (nreverse out) \" | \")))",
     ie_int (a, "handle", 0)));
}

static McpToolResult *
handle_set_color (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(progn (cmacs-imgedit-set-color %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT ") \"ok\")",
     ie_int (a, "handle", 0), ie_int (a, "r", 0), ie_int (a, "g", 0),
     ie_int (a, "b", 0), ie_int (a, "a", 255)));
}

static McpToolResult *
handle_draw_shape (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *shape = json_object_get_string_member (a, "shape");
  gint64 h = ie_int (a, "handle", 0);
  gint64 x1 = ie_int (a, "x1", 0), y1 = ie_int (a, "y1", 0);
  gint64 x2 = ie_int (a, "x2", 0), y2 = ie_int (a, "y2", 0);
  gint64 th = ie_int (a, "thickness", 1);
  const gchar *filled = (json_object_has_member (a, "filled")
    && json_object_get_boolean_member (a, "filled")) ? "t" : "nil";
  gchar *elisp = NULL;
  (void) s; (void) n; (void) u;

  if (g_strcmp0 (shape, "line") == 0)
    elisp = g_strdup_printf
      ("(cmacs-imgedit-draw-line %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT ")", h, x1, y1, x2, y2, th);
  else if (g_strcmp0 (shape, "arrow") == 0)
    elisp = g_strdup_printf
      ("(cmacs-imgedit-draw-arrow %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT ")", h, x1, y1, x2, y2, th);
  else if (g_strcmp0 (shape, "rect") == 0)
    elisp = g_strdup_printf
      ("(cmacs-imgedit-draw-rect %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %s %" G_GINT64_FORMAT ")", h, x1, y1, x2 - x1, y2 - y1, filled, th);
  else if (g_strcmp0 (shape, "circle") == 0)
    elisp = g_strdup_printf
      ("(cmacs-imgedit-draw-circle %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %s %" G_GINT64_FORMAT ")",
       h, x1, y1, x2, filled, th);   /* x2 = radius */
  else if (g_strcmp0 (shape, "ellipse") == 0)
    elisp = g_strdup_printf
      ("(cmacs-imgedit-draw-ellipse %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
       " %s %" G_GINT64_FORMAT ")", h, x1, y1, x2, y2, filled, th);
  else
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text
        (r, "shape must be line|arrow|rect|circle|ellipse");
      return r;
    }

  {
    gchar *wrapped = g_strdup_printf
      ("(progn (cmacs-imgedit-push-undo %" G_GINT64_FORMAT ") %s \"drawn\")",
       h, elisp);
    g_free (elisp);
    return ie_eval_result (wrapped);
  }
}

static McpToolResult *
handle_draw_text (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *text =
    ie_lisp_str (json_object_get_string_member (a, "text"));
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(progn (cmacs-imgedit-push-undo %" G_GINT64_FORMAT ")"
     " (cmacs-imgedit-draw-text %" G_GINT64_FORMAT " %" G_GINT64_FORMAT
     " %" G_GINT64_FORMAT " %s %" G_GINT64_FORMAT ") \"drawn\")",
     ie_int (a, "handle", 0), ie_int (a, "handle", 0),
     ie_int (a, "x", 0), ie_int (a, "y", 0), text,
     ie_int (a, "size", 16)));
}

static McpToolResult *
handle_add_layer (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *name = ie_lisp_str (json_object_has_member (a, "name")
    ? json_object_get_string_member (a, "name") : NULL);
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(format \"layer %%d\" (cmacs-imgedit-add-layer %" G_GINT64_FORMAT
     " %s))", ie_int (a, "handle", 0), name));
}

static McpToolResult *
handle_undo (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) u;
  return ie_eval_result (g_strdup_printf
    ("(if (cmacs-imgedit-undo %" G_GINT64_FORMAT ") \"undone\" \"nothing\")",
     ie_int (a, "handle", 0)));
}

static void
ie_add (McpServer *server, const gchar *name, const gchar *desc,
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
cmacs_mcp_tools_imgedit_register (McpServer *server)
{
  ie_add (server, "imgedit_new",
    "Create a WIDTHxHEIGHT image document; returns its handle.",
    "{\"type\":\"object\",\"properties\":{"
    "\"width\":{\"type\":\"integer\"},\"height\":{\"type\":\"integer\"}},"
    "\"required\":[\"width\",\"height\"]}", FALSE, handle_new);

  ie_add (server, "imgedit_open",
    "Open an image file (png/jpg/bmp/...); returns handle and size.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},"
    "\"required\":[\"path\"]}", FALSE, handle_open);

  ie_add (server, "imgedit_save",
    "Flatten and save the document (format by extension).",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"path\":{\"type\":\"string\"}},"
    "\"required\":[\"handle\",\"path\"]}", FALSE, handle_save);

  ie_add (server, "imgedit_info",
    "Describe the document: size, active layer, layer stack.",
    "{\"type\":\"object\",\"properties\":{\"handle\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\"]}", TRUE, handle_info);

  ie_add (server, "imgedit_set_color",
    "Set the draw colour (RGBA 0..255) used by the shape/text tools.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"r\":{\"type\":\"integer\"},"
    "\"g\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"},"
    "\"a\":{\"type\":\"integer\"}},\"required\":[\"handle\",\"r\",\"g\",\"b\"]}",
    FALSE, handle_set_color);

  ie_add (server, "imgedit_draw_shape",
    "Draw on the active layer (one undo step).  SHAPE: line|arrow (x1,y1 -> "
    "x2,y2), rect (corners x1,y1 / x2,y2), circle (centre x1,y1, radius x2), "
    "ellipse (centre x1,y1, radii x2,y2).  FILLED for rect/circle/ellipse.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"shape\":{\"type\":\"string\"},"
    "\"x1\":{\"type\":\"integer\"},\"y1\":{\"type\":\"integer\"},"
    "\"x2\":{\"type\":\"integer\"},\"y2\":{\"type\":\"integer\"},"
    "\"filled\":{\"type\":\"boolean\"},\"thickness\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\",\"shape\",\"x1\",\"y1\"]}",
    FALSE, handle_draw_shape);

  ie_add (server, "imgedit_draw_text",
    "Draw TEXT at X,Y in the current colour (SIZE px; one undo step).",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"x\":{\"type\":\"integer\"},"
    "\"y\":{\"type\":\"integer\"},\"text\":{\"type\":\"string\"},"
    "\"size\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\",\"x\",\"y\",\"text\"]}",
    FALSE, handle_draw_text);

  ie_add (server, "imgedit_add_layer",
    "Append a transparent layer (becomes active); returns its index.",
    "{\"type\":\"object\",\"properties\":{"
    "\"handle\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"}},"
    "\"required\":[\"handle\"]}", FALSE, handle_add_layer);

  ie_add (server, "imgedit_undo", "Undo the last edit on the document.",
    "{\"type\":\"object\",\"properties\":{\"handle\":{\"type\":\"integer\"}},"
    "\"required\":[\"handle\"]}", FALSE, handle_undo);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_IMGEDIT */
