/*
 * cmacs-mcp-tools-libregnum.c — libregnum level-editor MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools that drive the libregnum editor by dispatching Elisp
 * (`cmacs-libregnum-editor-*', `cmacs-lrgeditor-*') onto the active editor
 * buffer.  The MCP `eval' tool already reaches every DEFUN; these are
 * convenience wrappers with typed schemas so an agent can author levels
 * without hand-writing Elisp.
 *
 * The editor is libregnum's `lrgeditor'.  The embedded shell
 * (M-x cmacs-lrgeditor, buffer *lrgeditor*) is preferred when it is open;
 * the older Emacs-panel editor (*cmacs-libregnum editor*) otherwise.  Both
 * answer the same node DEFUNs, since the shell's LrgEditor is the one the
 * view's render context edits.  Tools are named `lrgeditor_*'; the
 * `lrg_editor_*' names they had before are registered too, for one
 * release, so existing agent prompts keep working.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_LIBREGNUM)

#include "lisp.h"
#include <string.h>
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#define LRG_SHELL_BUF  "*lrgeditor*"
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
  /* `shell' is non-nil when BUF is the embedded lrgeditor shell, so a body
     can prefer the shell's own actions (play/stop/save) over the older
     editor's DEFUNs. */
  gchar *out = g_strdup_printf
    ("(let* ((sb (get-buffer \"%s\"))"
     "        (shell (and sb (fboundp 'cmacs-lrgeditor-attached-p)"
     "                    (cmacs-lrgeditor-attached-p sb)))"
     "        (buf (or (and shell sb) (get-buffer \"%s\"))))"
     " (ignore shell)"
     " (if (and buf (cmacs-libregnum-editor-active-p buf)) (progn %s)"
     "   \"No libregnum editor open (M-x cmacs-lrgeditor)\"))",
     LRG_SHELL_BUF, LRG_EDITOR_BUF, body);
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
    ? json_object_get_string_member_with_default (a, "name", NULL) : "Object");
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
    ? json_object_get_string_member_with_default (a, "asset", NULL) : NULL);
  g_autofree gchar *name = lrg_lisp_str (json_object_has_member (a, "name")
    ? json_object_get_string_member_with_default (a, "name", NULL) : "Object");
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
    ? json_object_get_string_member_with_default (a, "path", NULL) : "level.rlevel");
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(progn (cmacs-libregnum-editor-save buf %s) \"saved\")", path)));
}

static McpToolResult *
handle_action (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *id = lrg_lisp_str (json_object_has_member (a, "id")
    ? json_object_get_string_member_with_default (a, "id", NULL) : NULL);
  (void) s; (void) n; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup_printf
    ("(if (not shell) \"The lrgeditor shell is not open (M-x cmacs-lrgeditor)\""
     " (if (cmacs-lrgeditor-activate-action buf %s) \"done\""
     "   \"unknown or disabled action\"))", id)));
}

static McpToolResult *
handle_actions (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup
    ("(if (not shell) \"The lrgeditor shell is not open (M-x cmacs-lrgeditor)\""
     " (mapconcat #'identity (cmacs-lrgeditor-actions buf) \"\\n\"))")));
}

static McpToolResult *
handle_socket (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup
    ("(or (and shell (cmacs-lrgeditor-socket buf))"
     " \"not serving the editor protocol\")")));
}

static McpToolResult *
handle_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  /* No path opens the shell on its welcome screen. */
  g_autofree gchar *path = lrg_lisp_str (json_object_has_member (a, "path")
    ? json_object_get_string_member_with_default (a, "path", NULL) : NULL);
  (void) s; (void) n; (void) u;
  /* Require first: in a session that never loaded cmacs-libregnum.el the
   * entry command -- and the C->Elisp click dispatchers defined alongside
   * it -- would be void (the same class as the gnuseye click bug). */
  return lrg_eval_result (g_strdup_printf
    ("(progn (require 'cmacs-lrgeditor) (cmacs-lrgeditor %s)"
     " \"opened\")", path));
}

static McpToolResult *
handle_play (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup
    ("(if (if shell (cmacs-lrgeditor-activate-action buf \"play.start\")"
     "       (cmacs-libregnum-editor-play buf))"
     "     \"playing\" \"could not instantiate\")")));
}

static McpToolResult *
handle_stop (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return lrg_eval_result (lrg_with_editor (g_strdup
    ("(progn (if shell (cmacs-lrgeditor-activate-action buf \"play.stop\")"
     "         (cmacs-libregnum-editor-stop buf))"
     " \"stopped\")")));
}

static void
lrg_add (McpServer *server, const gchar *name, const gchar *desc,
         const gchar *schema_json, gboolean read_only, gboolean legacy_too,
         McpToolResult *(*handler) (McpServer *, const gchar *,
                                    JsonObject *, gpointer))
{
  McpTool *tool;
  g_autofree gchar *legacy = NULL;

  /* Every tool is also reachable under its pre-rename `lrg_editor_*'
     name (see the file comment); new tools have no legacy name. */
  if (g_str_has_prefix (name, "lrgeditor_") && legacy_too)
    {
      legacy = g_strconcat ("lrg_editor_", name + strlen ("lrgeditor_"), NULL);
      lrg_add (server, legacy, desc, schema_json, read_only, FALSE, handler);
    }
  tool = mcp_tool_new (name, desc);
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
  lrg_add (server, "lrgeditor_object_tree",
    "List the libregnum editor's node tree (name/kind/depth/id).",
    NULL, TRUE, TRUE, handle_object_tree);

  lrg_add (server, "lrgeditor_add_primitive",
    "Add a primitive. PRIMITIVE: 0 plane,1 cube,2 circle,3 uv-sphere,"
    "4 ico-sphere,5 cylinder,6 cone,7 torus,8 grid.",
    "{\"type\":\"object\",\"properties\":{"
    "\"primitive\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"}},"
    "\"required\":[\"primitive\"]}", FALSE, TRUE, handle_add_primitive);

  lrg_add (server, "lrgeditor_add_visual",
    "Add a non-primitive node. KIND: 2 mesh-asset,3 sprite,4 tilemap,"
    "5 light,6 camera,7 audio. ASSET is the model/image/tileset file.",
    "{\"type\":\"object\",\"properties\":{"
    "\"kind\":{\"type\":\"integer\"},\"asset\":{\"type\":\"string\"},"
    "\"name\":{\"type\":\"string\"}},\"required\":[\"kind\"]}",
    FALSE, TRUE, handle_add_visual);

  lrg_add (server, "lrgeditor_move",
    "Set node ID's position to (X Y Z) as one undoable edit.",
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"integer\"},\"x\":{\"type\":\"number\"},"
    "\"y\":{\"type\":\"number\"},\"z\":{\"type\":\"number\"}},"
    "\"required\":[\"id\",\"x\",\"y\",\"z\"]}", FALSE, TRUE, handle_move);

  lrg_add (server, "lrgeditor_select", "Select node ID in the editor.",
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},"
    "\"required\":[\"id\"]}", FALSE, TRUE, handle_select);

  lrg_add (server, "lrgeditor_delete", "Delete node ID from the level.",
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},"
    "\"required\":[\"id\"]}", FALSE, TRUE, handle_delete);

  lrg_add (server, "lrgeditor_open",
    "Open libregnum's editor (the lrgeditor shell) on PATH: a project"
    " directory or a .rlevel file; no PATH opens its welcome screen.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
    FALSE, TRUE, handle_open);

  lrg_add (server, "lrgeditor_save", "Save the level to a .rlevel PATH.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},"
    "\"required\":[\"path\"]}", FALSE, TRUE, handle_save);

  lrg_add (server, "lrgeditor_play",
    "Play-in-editor: instantiate the level into a runtime world and run it.",
    NULL, FALSE, TRUE, handle_play);

  lrg_add (server, "lrgeditor_stop", "Stop play-in-editor.",
    NULL, FALSE, TRUE, handle_stop);

  lrg_add (server, "lrgeditor_action",
    "Run an lrgeditor action by id (e.g. file.save, edit.undo, play.start,"
    " view.top) in the embedded shell. lrgeditor_actions lists them.",
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},"
    "\"required\":[\"id\"]}", FALSE, FALSE, handle_action);

  lrg_add (server, "lrgeditor_actions",
    "List the action ids the embedded lrgeditor shell registers.",
    NULL, TRUE, FALSE, handle_actions);

  lrg_add (server, "lrgeditor_socket",
    "Socket the embedded lrgeditor serves libregnum's editor protocol on"
    " (for lrgeditorctl --socket, its MCP verbs, or libregnum.el).",
    NULL, TRUE, FALSE, handle_socket);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_LIBREGNUM */
