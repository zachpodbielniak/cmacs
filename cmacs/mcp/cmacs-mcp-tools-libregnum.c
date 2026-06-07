/*
 * cmacs-mcp-tools-libregnum.c — libregnum level-editor MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools that drive the libregnum editor by dispatching Elisp
 * (`cmacs-libregnum-editor-*') onto the active editor buffer.  The MCP `eval'
 * tool already reaches every DEFUN; these are convenience wrappers with typed
 * schemas so an agent can author levels without hand-writing Elisp.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_LIBREGNUM)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#define LRG_EDITOR_BUF "*cmacs-libregnum editor*"

/* Render STR as an Elisp string literal ("..." with " and \\ escaped), or the
 * symbol `nil' when STR is NULL.  Caller frees. */
static gchar *
lrg_lisp_str (const gchar *str)
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
lrg_eval_result (gchar *elisp)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *src = elisp;
  g_autofree gchar *out = cmacs_dispatch_eval (src, &error);
  McpToolResult *result = mcp_tool_result_new (out == NULL);
  mcp_tool_result_add_text (result,
    out ? out : (error ? error->message : "error"));
  return result;
}

/* Wrap BODY so it runs with `buf' bound to the active editor buffer, erroring
 * nicely when no editor is open.  Takes ownership of BODY. */
static gchar *
lrg_with_editor (gchar *body)
{
  gchar *out = g_strdup_printf
    ("(let ((buf (get-buffer \"%s\")))"
     " (if (and buf (cmacs-libregnum-editor-active-p buf)) (progn %s)"
     "   \"No libregnum editor open (M-x cmacs-libregnum-editor)\"))",
     LRG_EDITOR_BUF, body);
  g_free (body);
  return out;
}

static McpToolResult *
handle_object_tree (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lrg_eval_result
    (lrg_with_editor (g_strdup
       ("(format \"%S\" (cmacs-libregnum-tree-nodes buf))")));
}

static McpToolResult *
handle_add_primitive (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gint64 prim = json_object_has_member (a, "primitive")
    ? json_object_get_int_member (a, "primitive") : 1;
  g_autofree gchar *name = lrg_lisp_str (json_object_has_member (a, "name")
    ? json_object_get_string_member (a, "name") : "Object");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(format \"added node %%S\""
     " (cmacs-libregnum-editor-add-primitive buf %" G_GINT64_FORMAT " %s))",
     prim, name)));
}

static McpToolResult *
handle_add_visual (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gint64 kind = json_object_has_member (a, "kind")
    ? json_object_get_int_member (a, "kind") : 2;
  g_autofree gchar *asset = lrg_lisp_str (json_object_has_member (a, "asset")
    ? json_object_get_string_member (a, "asset") : NULL);
  g_autofree gchar *name = lrg_lisp_str (json_object_has_member (a, "name")
    ? json_object_get_string_member (a, "name") : "Object");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(format \"added node %%S\""
     " (cmacs-libregnum-editor-add-visual buf %" G_GINT64_FORMAT " %s %s))",
     kind, asset, name)));
}

static McpToolResult *
handle_move (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gint64 id = json_object_get_int_member (a, "id");
  double x = json_object_get_double_member (a, "x");
  double y = json_object_get_double_member (a, "y");
  double z = json_object_get_double_member (a, "z");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(progn (cmacs-libregnum-editor-set-position buf %" G_GINT64_FORMAT
     " %g %g %g) \"moved\")", id, x, y, z)));
}

static McpToolResult *
handle_select (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gint64 id = json_object_get_int_member (a, "id");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(progn (cmacs-libregnum-editor-select buf %" G_GINT64_FORMAT
     ") \"selected\")", id)));
}

static McpToolResult *
handle_delete (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gint64 id = json_object_get_int_member (a, "id");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(progn (cmacs-libregnum-editor-delete buf %" G_GINT64_FORMAT
     ") \"deleted\")", id)));
}

static McpToolResult *
handle_save (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *path = lrg_lisp_str (json_object_has_member (a, "path")
    ? json_object_get_string_member (a, "path") : "level.rlevel");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(progn (cmacs-libregnum-editor-save buf %s) \"saved\")", path)));
}

static McpToolResult *
handle_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *path = lrg_lisp_str (json_object_has_member (a, "path")
    ? json_object_get_string_member (a, "path") : "level.rlevel");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (g_strdup_printf
    ("(progn (cmacs-libregnum-editor %s) \"opened\")", path));
}

static McpToolResult *
handle_play (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup
    ("(if (cmacs-libregnum-editor-play buf) \"playing\""
     " \"could not instantiate\")")));
}

static McpToolResult *
handle_stop (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup
    ("(progn (cmacs-libregnum-editor-stop buf) \"stopped\")")));
}

static void
lrg_add (McpServer *server, const gchar *name, const gchar *desc,
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
cmacs_mcp_tools_libregnum_register (McpServer *server)
{
  lrg_add (server, "lrg_editor_object_tree",
    "List the libregnum editor's node tree (name/kind/depth/id).",
    NULL, TRUE, handle_object_tree);

  lrg_add (server, "lrg_editor_add_primitive",
    "Add a primitive. PRIMITIVE: 0 plane,1 cube,2 circle,3 uv-sphere,"
    "4 ico-sphere,5 cylinder,6 cone,7 torus,8 grid.",
    "{\"type\":\"object\",\"properties\":{"
    "\"primitive\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"}},"
    "\"required\":[\"primitive\"]}", FALSE, handle_add_primitive);

  lrg_add (server, "lrg_editor_add_visual",
    "Add a non-primitive node. KIND: 2 mesh-asset,3 sprite,4 tilemap,"
    "5 light,6 camera,7 audio. ASSET is the model/image/tileset file.",
    "{\"type\":\"object\",\"properties\":{"
    "\"kind\":{\"type\":\"integer\"},\"asset\":{\"type\":\"string\"},"
    "\"name\":{\"type\":\"string\"}},\"required\":[\"kind\"]}",
    FALSE, handle_add_visual);

  lrg_add (server, "lrg_editor_move",
    "Set node ID's position to (X Y Z) as one undoable edit.",
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"integer\"},\"x\":{\"type\":\"number\"},"
    "\"y\":{\"type\":\"number\"},\"z\":{\"type\":\"number\"}},"
    "\"required\":[\"id\",\"x\",\"y\",\"z\"]}", FALSE, handle_move);

  lrg_add (server, "lrg_editor_select", "Select node ID in the editor.",
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},"
    "\"required\":[\"id\"]}", FALSE, handle_select);

  lrg_add (server, "lrg_editor_delete", "Delete node ID from the level.",
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},"
    "\"required\":[\"id\"]}", FALSE, handle_delete);

  lrg_add (server, "lrg_editor_open",
    "Open (or create) the libregnum editor on a .rlevel PATH.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},"
    "\"required\":[\"path\"]}", FALSE, handle_open);

  lrg_add (server, "lrg_editor_save", "Save the level to a .rlevel PATH.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},"
    "\"required\":[\"path\"]}", FALSE, handle_save);

  lrg_add (server, "lrg_editor_play",
    "Play-in-editor: instantiate the level into a runtime world and run it.",
    NULL, FALSE, handle_play);

  lrg_add (server, "lrg_editor_stop", "Stop play-in-editor.",
    NULL, FALSE, handle_stop);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_LIBREGNUM */
