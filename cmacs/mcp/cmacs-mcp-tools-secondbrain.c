/*
 * cmacs-mcp-tools-secondbrain.c — ARMS second-brain MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools that drive the second-brain visualiser and its ingester
 * by dispatching Elisp.  The MCP `eval' tool already reaches every DEFUN;
 * these add typed schemas so an agent can open the view, switch layouts,
 * expand a department, search it, and -- the ones that matter to an
 * agent doing research -- file things into the notes and find them again,
 * without hand-writing Elisp.
 *
 * D-Bus parity: every tool here has a method on org.cmacs.Editor1.SecondBrain
 * (cmacs/dbus/cmacs-dbus-iface-secondbrain.c) with the same Elisp body.
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

/* ── The ingester: needs no open view ──────────────────────────────── */

#define SB_INGEST "(progn (require 'cmacs-secondbrain-ingest) "

/* A string member, or NULL when absent or empty. */
static const gchar *
sb_str_member (JsonObject *a, const gchar *name)
{
  const gchar *v;
  if (a == NULL || !json_object_has_member (a, name))
    return NULL;
  v = json_object_get_string_member_with_default (a, name, NULL);
  return (v != NULL && *v != '\0') ? v : NULL;
}

static McpToolResult *
handle_ingest (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *input = sb_str_member (a, "input");
  const gchar *text = sb_str_member (a, "text");
  JsonBuilder *b;
  JsonGenerator *gen;
  JsonNode *root;
  g_autofree gchar *inputs = NULL;
  g_autofree gchar *options = NULL;
  g_autofree gchar *qi = NULL;
  g_autofree gchar *qo = NULL;
  static const gchar *string_opts[] = {
    "para", "category", "directory", "tags", "type", "prompt", "provider",
    "model", "name", "title", "format", "include", "exclude", "root",
    "branch", "web_backend", "text", "sanitize", NULL
  };
  static const gchar *bool_opts[] = {
    "principle", "no_summary", "no_ai", "crawl", "recursive", "append",
    "dry_run", "keep_source", NULL
  };
  static const gchar *int_opts[] = { "depth", "max_pages", NULL };
  gint k;
  (void) s; (void) n; (void) u;

  if (input == NULL && text == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "secondbrain_ingest: give 'input' (a URL "
                                "or absolute path) or 'text'");
      return r;
    }

  /* The inputs array: one URL or path, or none when text is given. */
  b = json_builder_new ();
  json_builder_begin_array (b);
  if (input != NULL)
    json_builder_add_string_value (b, input);
  json_builder_end_array (b);
  root = json_builder_get_root (b);
  gen = json_generator_new ();
  json_generator_set_root (gen, root);
  inputs = json_generator_to_data (gen, NULL);
  json_node_free (root);
  g_object_unref (gen);
  g_object_unref (b);

  /* The options object: copy the members we understand, typed.  Every
     value came from a model; nothing is interpolated into Elisp except
     through sb_lisp_str, and the Elisp side validates again. */
  b = json_builder_new ();
  json_builder_begin_object (b);
  for (k = 0; string_opts[k] != NULL; k++)
    {
      const gchar *v = sb_str_member (a, string_opts[k]);
      if (v != NULL)
        {
          json_builder_set_member_name (b, string_opts[k]);
          json_builder_add_string_value (b, v);
        }
    }
  for (k = 0; bool_opts[k] != NULL; k++)
    if (a && json_object_has_member (a, bool_opts[k])
        && json_object_get_boolean_member_with_default (a, bool_opts[k], FALSE))
      {
        json_builder_set_member_name (b, bool_opts[k]);
        json_builder_add_boolean_value (b, TRUE);
      }
  for (k = 0; int_opts[k] != NULL; k++)
    if (a && json_object_has_member (a, int_opts[k]))
      {
        json_builder_set_member_name (b, int_opts[k]);
        json_builder_add_int_value (
          b, json_object_get_int_member_with_default (a, int_opts[k], 0));
      }
  if (a && json_object_has_member (a, "link")
      && !json_object_get_boolean_member_with_default (a, "link", TRUE))
    {
      json_builder_set_member_name (b, "link");
      json_builder_add_boolean_value (b, FALSE);
    }
  /* keep_source is a string on the Elisp side ("copy"). */
  if (a && json_object_has_member (a, "keep_source")
      && json_object_get_boolean_member_with_default (a, "keep_source", FALSE))
    {
      json_builder_set_member_name (b, "keep_source");
      json_builder_add_string_value (b, "copy");
    }
  json_builder_end_object (b);
  root = json_builder_get_root (b);
  gen = json_generator_new ();
  json_generator_set_root (gen, root);
  options = json_generator_to_data (gen, NULL);
  json_node_free (root);
  g_object_unref (gen);
  g_object_unref (b);

  qi = sb_lisp_str (inputs);
  qo = sb_lisp_str (options);
  return sb_eval_result (g_strdup_printf
    (SB_INGEST "(cmacs-secondbrain-ingest-from-json %s %s))", qi, qo));
}

static McpToolResult *
handle_ingest_status (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *id = sb_str_member (a, "id");
  (void) s; (void) n; (void) u;

  if (id == NULL)
    return sb_eval_result (g_strdup
      (SB_INGEST "(cmacs-secondbrain-ingest-list-json))"));
  {
    g_autofree gchar *qi = sb_lisp_str (id);
    return sb_eval_result (g_strdup_printf
      (SB_INGEST "(cmacs-secondbrain-ingest-status-json %s))", qi));
  }
}

static McpToolResult *
handle_ingest_cancel (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *id = sb_str_member (a, "id");
  (void) s; (void) n; (void) u;

  if (id == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "secondbrain_ingest_cancel: missing 'id'");
      return r;
    }
  {
    g_autofree gchar *qi = sb_lisp_str (id);
    return sb_eval_result (g_strdup_printf
      (SB_INGEST "(cmacs-secondbrain-ingest-cancel %s)"
       " (cmacs-secondbrain-ingest-status-json %s))", qi, qi));
  }
}

static McpToolResult *
handle_tree (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *para = sb_str_member (a, "para");
  const gchar *category = sb_str_member (a, "category");
  gboolean files = a && json_object_has_member (a, "files")
    && json_object_get_boolean_member_with_default (a, "files", FALSE);
  g_autofree gchar *qp = para ? sb_lisp_str (para) : g_strdup ("nil");
  g_autofree gchar *qc = category ? sb_lisp_str (category) : g_strdup ("nil");
  (void) s; (void) n; (void) u;

  return sb_eval_result (g_strdup_printf
    (SB_INGEST "(json-serialize (vconcat"
     " (cmacs-secondbrain-ingest-tree nil %s %s %s))))",
     qp, qc, files ? "t" : "nil"));
}

static McpToolResult *
handle_find (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  const gchar *query = sb_str_member (a, "query");
  gint64 limit = (a && json_object_has_member (a, "limit"))
    ? json_object_get_int_member_with_default (a, "limit", 10) : 10;
  (void) s; (void) n; (void) u;

  if (query == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "secondbrain_find: missing 'query'");
      return r;
    }
  if (limit <= 0) limit = 10;
  {
    g_autofree gchar *q = sb_lisp_str (query);
    return sb_eval_result (g_strdup_printf
      (SB_INGEST "(cmacs-secondbrain-ingest-find-json %s %d))",
       q, (gint) limit));
  }
}

static McpToolResult *
handle_doctor (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return sb_eval_result (g_strdup
    (SB_INGEST "(json-serialize (vconcat (mapcar (lambda (e)"
     "  (list :name (symbol-name (nth 0 e)) :available (and (nth 1 e) t)"
     "        :detail (nth 2 e)))"
     " (cmacs-secondbrain-ingest-doctor)))))"));
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

  /* The ingester. */
  sb_add (server, "secondbrain_ingest",
    "File a URL, a file (PDF, Office, EPUB, mail, audio, video, YouTube, "
    "HTML, Markdown, data...) or literal text into the user's second brain "
    "as an Org note: summarised, tagged, placed in the PARA tree, linked to "
    "related notes and registered in its index.  Returns the QUEUED jobs "
    "with ids; the work runs asynchronously -- poll secondbrain_ingest_status "
    "until 'done' is true and read 'note_file'.  Set 'dry_run' to see the "
    "plan without doing anything.  Paths must be absolute.",
    "{\"type\":\"object\",\"properties\":{"
    "\"input\":{\"type\":\"string\",\"description\":\"URL or absolute path; omit when text is given\"},"
    "\"text\":{\"type\":\"string\",\"description\":\"Literal text to ingest\"},"
    "\"para\":{\"type\":\"string\",\"enum\":[\"inbox\",\"projects\",\"areas\",\"resources\",\"detect\"]},"
    "\"category\":{\"type\":\"string\",\"description\":\"Sub path under the category, e.g. technical/linux\"},"
    "\"directory\":{\"type\":\"string\",\"description\":\"Exact root-relative directory, overriding para/category\"},"
    "\"tags\":{\"type\":\"string\",\"description\":\"Comma-separated tags\"},"
    "\"type\":{\"type\":\"string\",\"description\":\"Summary template: auto, general, meeting, book, youtube, ...\"},"
    "\"prompt\":{\"type\":\"string\",\"description\":\"Extra summary instructions\"},"
    "\"principle\":{\"type\":\"boolean\"},"
    "\"no_summary\":{\"type\":\"boolean\"},"
    "\"no_ai\":{\"type\":\"boolean\"},"
    "\"sanitize\":{\"type\":\"string\",\"description\":\"'t' for the default redaction rules, or a comma list of rule names\"},"
    "\"title\":{\"type\":\"string\"},"
    "\"name\":{\"type\":\"string\",\"description\":\"File name seed\"},"
    "\"format\":{\"type\":\"string\",\"description\":\"Format of text: org, markdown, text, json, csv, html\"},"
    "\"crawl\":{\"type\":\"boolean\"},"
    "\"depth\":{\"type\":\"integer\"},"
    "\"max_pages\":{\"type\":\"integer\"},"
    "\"append\":{\"type\":\"boolean\"},"
    "\"link\":{\"type\":\"boolean\",\"description\":\"false to skip related notes\"},"
    "\"keep_source\":{\"type\":\"boolean\",\"description\":\"Copy the original beside the note\"},"
    "\"dry_run\":{\"type\":\"boolean\"}}}",
    FALSE, handle_ingest);

  sb_add (server, "secondbrain_ingest_status",
    "Status of an ingest job by 'id' (stage, progress, note_file, warnings, "
    "error, done); without an id, every job.",
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"string\"}}}",
    TRUE, handle_ingest_status);

  sb_add (server, "secondbrain_ingest_cancel",
    "Cancel an ingest job by id.",
    "{\"type\":\"object\",\"properties\":{"
    "\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
    FALSE, handle_ingest_cancel);

  sb_add (server, "secondbrain_tree",
    "List the PARA notes tree as root-relative paths, optionally narrowed "
    "to one category and sub path, optionally with .org files.  Use it to "
    "see where a note could be filed.",
    "{\"type\":\"object\",\"properties\":{"
    "\"para\":{\"type\":\"string\"},"
    "\"category\":{\"type\":\"string\"},"
    "\"files\":{\"type\":\"boolean\"}}}",
    TRUE, handle_tree);

  sb_add (server, "secondbrain_find",
    "Search the notes for a query: semantic (embeddings + lexical fusion) "
    "when the memory index exists, text search otherwise.  Returns path, "
    "title, score and snippet per hit.",
    "{\"type\":\"object\",\"properties\":{"
    "\"query\":{\"type\":\"string\"},"
    "\"limit\":{\"type\":\"integer\"}},\"required\":[\"query\"]}",
    TRUE, handle_find);

  sb_add (server, "secondbrain_doctor",
    "Which external programs (pandoc, pdftotext, yt-dlp, ffmpeg, ...) and "
    "cmacs features (office, whisper, ai) the ingester can use on this host.",
    NULL, TRUE, handle_doctor);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_SECONDBRAIN */
