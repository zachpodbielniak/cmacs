/*
 * cmacs-mcp-tools-secondbrain.c — ARMS second-brain MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools that drive the second-brain visualiser by dispatching
 * Elisp.  The MCP `eval' tool already reaches every DEFUN; these add typed
 * schemas so an agent can open the view, switch layouts, expand a
 * department and search it without hand-writing Elisp.
 *
 * Every interpolated argument goes through sb_lisp_str: these are
 * attacker-controlled tool arguments being spliced into a form that is
 * about to be evaluated.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_SECONDBRAIN)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Render STR as an Elisp string literal, or `nil' when NULL.  Caller frees. */
static gchar *
sb_lisp_str (const gchar *str)
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
sb_eval_result (gchar *elisp)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *src = elisp;
  g_autofree gchar *out = cmacs_dispatch_eval (src, &error);
  McpToolResult *result = mcp_tool_result_new (out == NULL);
  mcp_tool_result_add_text (result,
    out ? out : (error ? error->message : "error"));
  return result;
}

/* Every tool below operates on the one second-brain buffer, so they all
 * need the same preamble: require the feature and find that buffer.
 * Returns a form evaluating to the buffer, or signalling if the view is
 * not open -- which is a better answer than silently doing nothing. */
#define SB_BUF                                                          \
  "(progn (require 'cmacs-secondbrain)"                                 \
  " (or (get-buffer cmacs-secondbrain-buffer-name)"                     \
  "     (error \"the second brain is not open; call secondbrain_open\")))"

static McpToolResult *
handle_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  gboolean three_d = FALSE;
  (void) s; (void) n; (void) u;

  if (a && json_object_has_member (a, "three_d"))
    three_d = json_object_get_boolean_member (a, "three_d");

  return sb_eval_result (g_strdup_printf
    ("(progn (require 'cmacs-secondbrain) (%s) \"opened\")",
     three_d ? "cmacs-secondbrain-3d" : "cmacs-secondbrain"));
}

static McpToolResult *
handle_set_layout (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *kind;
  (void) s; (void) n; (void) u;

  /* `_with_default', never the bare accessor: the bare one asserts
     when the member is absent, and a missing argument from a model is
     ordinary input, not a programming error.  A test enforces this. */
  kind = a ? json_object_get_string_member_with_default (a, "kind", "rings")
           : "rings";
  if (!kind) kind = "rings";

  /* Interned rather than interpolated raw: the value reaches `intern',
     and an argument that can name any symbol is an argument that can
     name one you did not intend. */
  {
    g_autofree gchar *k = sb_lisp_str (kind);
    return sb_eval_result (g_strdup_printf
      ("(with-current-buffer %s"
       " (cmacs-secondbrain-set-layout-interactive (intern %s))"
       " (format \"%%s\" (cmacs-secondbrain-layout-kind (current-buffer))))",
       SB_BUF, k));
  }
}

static McpToolResult *
handle_search (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *query;
  gboolean semantic = FALSE;
  (void) s; (void) n; (void) u;

  query = a ? json_object_get_string_member_with_default (a, "query", NULL)
            : NULL;
  if (!query || !*query)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "secondbrain_search: missing 'query'");
      return r;
    }
  if (a && json_object_has_member (a, "semantic"))
    semantic = json_object_get_boolean_member (a, "semantic");

  {
    g_autofree gchar *q = sb_lisp_str (query);
    return sb_eval_result (g_strdup_printf
      ("(with-current-buffer %s (%s %s))",
       SB_BUF,
       semantic ? "cmacs-secondbrain-search-semantic"
                : "cmacs-secondbrain-search",
       q));
  }
}

static McpToolResult *
handle_expand (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *id;
  gboolean collapse = FALSE;
  (void) s; (void) n; (void) u;

  id = a ? json_object_get_string_member_with_default (a, "id", NULL) : NULL;
  if (a && json_object_has_member (a, "collapse"))
    collapse = json_object_get_boolean_member (a, "collapse");

  if (!id || !*id)
    return sb_eval_result (g_strdup_printf
      ("(with-current-buffer %s (cmacs-secondbrain-collapse-all"
       " (current-buffer) %s 0) \"ok\")",
       SB_BUF, collapse ? "t" : "nil"));

  {
    g_autofree gchar *i = sb_lisp_str (id);
    return sb_eval_result (g_strdup_printf
      ("(with-current-buffer %s"
       " (if (cmacs-secondbrain-set-collapsed (current-buffer) %s %s 0)"
       "     \"changed\" \"no change\"))",
       SB_BUF, i, collapse ? "t" : "nil"));
  }
}

static McpToolResult *
handle_node_info (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *id;
  (void) s; (void) n; (void) u;

  id = a ? json_object_get_string_member_with_default (a, "id", NULL) : NULL;
  if (!id || !*id)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "secondbrain_node_info: missing 'id'");
      return r;
    }

  {
    g_autofree gchar *i = sb_lisp_str (id);
    return sb_eval_result (g_strdup_printf
      ("(with-current-buffer %s"
       " (format \"%%S\" (cmacs-secondbrain-node-at (current-buffer) %s)))",
       SB_BUF, i));
  }
}

static McpToolResult *
handle_stats (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return sb_eval_result (g_strdup_printf
    ("(with-current-buffer %s"
     " (format \"nodes=%%s visible=%%s edges=%%s layout=%%s\""
     "  (cmacs-secondbrain-node-count (current-buffer))"
     "  (cmacs-secondbrain-visible-count (current-buffer))"
     "  (cmacs-secondbrain-edge-count (current-buffer))"
     "  (cmacs-secondbrain-layout-kind (current-buffer))))",
     SB_BUF));
}

static McpToolResult *
handle_sources (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return sb_eval_result (g_strdup
    ("(progn (require 'cmacs-secondbrain)"
     " (format \"%S\" (cmacs-secondbrain-sources)))"));
}

static McpToolResult *
handle_refresh (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return sb_eval_result (g_strdup_printf
    ("(with-current-buffer %s (cmacs-secondbrain-refresh) \"refreshed\")",
     SB_BUF));
}

static void
sb_add (McpServer *server, const gchar *name, const gchar *desc,
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
cmacs_mcp_tools_secondbrain_register (McpServer *server)
{
  sb_add (server, "secondbrain_open",
    "Open the ARMS second-brain visualiser: the user's agentic workspace "
    "as four concentric rings (Applications, Routines, Memory, Skills). "
    "Set 'three_d' for the free 3D view rather than the flat one.",
    "{\"type\":\"object\",\"properties\":{"
    "\"three_d\":{\"type\":\"boolean\",\"description\":\"Free 3D view\"}}}",
    FALSE, handle_open);

  sb_add (server, "secondbrain_set_layout",
    "Switch the layout.  'rings' is the ARMS layout (concentric bands), "
    "'circle' one circle per department, 'hex' a hex lattice, 'force' a "
    "force-directed graph.  The change animates.",
    "{\"type\":\"object\",\"properties\":{"
    "\"kind\":{\"type\":\"string\","
    "\"enum\":[\"rings\",\"circle\",\"hex\",\"force\"]}},"
    "\"required\":[\"kind\"]}",
    FALSE, handle_set_layout);

  sb_add (server, "secondbrain_search",
    "Highlight nodes matching QUERY, dimming the rest.  By default a "
    "substring match over names and paths, which is instant.  Set "
    "'semantic' to embed the query and rank against the notes index "
    "instead -- slower, and worth it only when you do not know the name.",
    "{\"type\":\"object\",\"properties\":{"
    "\"query\":{\"type\":\"string\"},"
    "\"semantic\":{\"type\":\"boolean\"}},"
    "\"required\":[\"query\"]}",
    FALSE, handle_search);

  sb_add (server, "secondbrain_expand",
    "Expand or collapse a department.  With 'id', acts on that node; "
    "without one, acts on every department at once.  Departments start "
    "collapsed, so this is how you see what is inside one.",
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"string\",\"description\":\"Node id; omit for all\"},"
    "\"collapse\":{\"type\":\"boolean\",\"description\":\"Collapse instead\"}}}",
    FALSE, handle_expand);

  sb_add (server, "secondbrain_node_info",
    "Return the full record for a node id: title, role, ARMS ring, "
    "department and file.",
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
    TRUE, handle_node_info);

  sb_add (server, "secondbrain_stats",
    "Counts for the open view: total nodes, how many are visible (the "
    "rest are inside collapsed departments), edges, and the layout.",
    NULL, TRUE, handle_stats);

  sb_add (server, "secondbrain_sources",
    "List the registered ARMS data sources -- where each ring's contents "
    "come from.",
    NULL, TRUE, handle_sources);

  sb_add (server, "secondbrain_refresh",
    "Re-read every enabled source and rebuild the graph.",
    NULL, FALSE, handle_refresh);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_SECONDBRAIN */
