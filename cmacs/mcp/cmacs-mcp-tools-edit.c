/*
 * cmacs-mcp-tools-edit.c — Editing and search MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Structured editing primitives that an AI agent reaches for routinely:
 * string-replace edits, regexp replace, in-buffer search, line
 * navigation, and project-wide grep.  All handlers dispatch elisp
 * through cmacs_dispatch_eval().
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Helper: build an error result with MESSAGE. */
static McpToolResult *
edit_error (const gchar *message)
{
  McpToolResult *result = mcp_tool_result_new (TRUE);
  mcp_tool_result_add_text (result, message);
  return result;
}

/* Helper: dispatch EXPR, wrap printed result (or error) in a result. */
static McpToolResult *
edit_dispatch (const gchar *expr)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *str = cmacs_dispatch_eval (expr, &error);
  McpToolResult *result = mcp_tool_result_new (str == NULL);
  mcp_tool_result_add_text (result, str ? str : error->message);
  return result;
}

/* ── get_org_content ──────────────────────────────────────────────── */

/* D-Bus parity: Edit.GetOrgContent in cmacs-dbus-iface-edit.c (both
   call cmacs_dispatch_org_content). */
static McpToolResult *
handle_get_org_content (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  const gchar *buffer, *match;
  gint64 max_depth;
  gboolean include_body, include_props;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *json = NULL;
  McpToolResult *result;

  (void) s; (void) n; (void) u;

  buffer = json_object_get_string_member_with_default (a, "buffer",
                                                       NULL);
  if (buffer == NULL)
    return edit_error ("Missing required argument: buffer");
  match = json_object_get_string_member_with_default (a, "match", NULL);
  max_depth = json_object_get_int_member_with_default (a, "max_depth",
                                                       0);
  include_body = json_object_get_boolean_member_with_default (
    a, "include_body", TRUE);
  include_props = json_object_get_boolean_member_with_default (
    a, "include_properties", TRUE);

  json = cmacs_dispatch_org_content (buffer, match, (gint) max_depth,
                                     include_body, include_props,
                                     &error);
  result = mcp_tool_result_new (json == NULL);
  mcp_tool_result_add_text (result, json ? json : error->message);
  return result;
}

/* ── edit_buffer ──────────────────────────────────────────────────── */

static McpToolResult *
handle_edit_buffer (McpServer *s, const gchar *n,
                    JsonObject *a, gpointer u)
{
  const gchar *buffer, *old_string, *new_string;
  g_autofree gchar *eb = NULL, *eo = NULL, *en = NULL, *expr = NULL;
  gboolean replace_all = FALSE;

  (void) s; (void) n; (void) u;

  buffer = json_object_get_string_member (a, "buffer");
  old_string = json_object_get_string_member (a, "old_string");
  new_string = json_object_get_string_member (a, "new_string");
  if (buffer == NULL || old_string == NULL || new_string == NULL)
    return edit_error (
      "Missing required arguments: buffer, old_string, new_string");
  if (json_object_has_member (a, "replace_all"))
    replace_all = json_object_get_boolean_member (a, "replace_all");

  eb = g_strescape (buffer, NULL);
  eo = g_strescape (old_string, NULL);
  en = g_strescape (new_string, NULL);

  expr = g_strdup_printf (
    "(with-current-buffer \"%s\""
    "  (let ((old \"%s\") (new \"%s\") (all %s)"
    "        (case-fold-search nil) (cnt 0))"
    "    (save-excursion"
    "      (goto-char (point-min))"
    "      (while (search-forward old nil t) (setq cnt (1+ cnt))))"
    "    (cond"
    "     ((= cnt 0) (error \"old_string not found in buffer\"))"
    "     ((and (> cnt 1) (not all))"
    "      (error \"old_string matches %%d times; pass replace_all\" cnt))"
    "     (t (save-excursion"
    "          (goto-char (point-min))"
    "          (let ((m 0))"
    "            (while (and (search-forward old nil t)"
    "                        (or all (= m 0)))"
    "              (replace-match new t t)"
    "              (setq m (1+ m)))"
    "            (format \"replaced %%d occurrence(s)\" m)))))))",
    eb, eo, en, replace_all ? "t" : "nil");

  return edit_dispatch (expr);
}

/* ── replace_in_buffer ────────────────────────────────────────────── */

static McpToolResult *
handle_replace_in_buffer (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  const gchar *buffer, *regexp, *replacement;
  g_autofree gchar *eb = NULL, *er = NULL, *ep = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  buffer = json_object_get_string_member (a, "buffer");
  regexp = json_object_get_string_member (a, "regexp");
  replacement = json_object_get_string_member (a, "replacement");
  if (buffer == NULL || regexp == NULL || replacement == NULL)
    return edit_error (
      "Missing required arguments: buffer, regexp, replacement");

  eb = g_strescape (buffer, NULL);
  er = g_strescape (regexp, NULL);
  ep = g_strescape (replacement, NULL);

  expr = g_strdup_printf (
    "(with-current-buffer \"%s\""
    "  (save-excursion"
    "    (goto-char (point-min))"
    "    (let ((c 0))"
    "      (while (re-search-forward \"%s\" nil t)"
    "        (replace-match \"%s\" t nil) (setq c (1+ c)))"
    "      (format \"replaced %%d match(es)\" c))))",
    eb, er, ep);

  return edit_dispatch (expr);
}

/* ── search_buffer ────────────────────────────────────────────────── */

static McpToolResult *
handle_search_buffer (McpServer *s, const gchar *n,
                      JsonObject *a, gpointer u)
{
  const gchar *buffer, *regexp;
  g_autofree gchar *eb = NULL, *er = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  buffer = json_object_get_string_member (a, "buffer");
  regexp = json_object_get_string_member (a, "regexp");
  if (buffer == NULL || regexp == NULL)
    return edit_error ("Missing required arguments: buffer, regexp");

  eb = g_strescape (buffer, NULL);
  er = g_strescape (regexp, NULL);

  expr = g_strdup_printf (
    "(with-current-buffer \"%s\""
    "  (save-excursion"
    "    (goto-char (point-min))"
    "    (let ((out '()) (n 0))"
    "      (while (and (< n 200) (re-search-forward \"%s\" nil t))"
    "        (push (format \"%%d: %%s\" (line-number-at-pos)"
    "                      (buffer-substring-no-properties"
    "                       (line-beginning-position)"
    "                       (line-end-position)))"
    "              out)"
    "        (setq n (1+ n))"
    "        (forward-line 1))"
    "      (if out (mapconcat #'identity (nreverse out) \"\\n\")"
    "        \"(no matches)\"))))",
    eb, er);

  return edit_dispatch (expr);
}

/* ── goto_line ────────────────────────────────────────────────────── */

static McpToolResult *
handle_goto_line (McpServer *s, const gchar *n,
                  JsonObject *a, gpointer u)
{
  const gchar *buffer;
  g_autofree gchar *eb = NULL, *expr = NULL;
  gint64 line;

  (void) s; (void) n; (void) u;

  buffer = json_object_get_string_member (a, "buffer");
  if (buffer == NULL || !json_object_has_member (a, "line"))
    return edit_error ("Missing required arguments: buffer, line");
  line = json_object_get_int_member (a, "line");

  eb = g_strescape (buffer, NULL);
  expr = g_strdup_printf (
    "(with-current-buffer \"%s\""
    "  (goto-char (point-min))"
    "  (forward-line (1- %ld))"
    "  (let ((w (get-buffer-window (current-buffer) t)))"
    "    (when w (set-window-point w (point))))"
    "  (format \"line %%d at point %%d\""
    "          (line-number-at-pos) (point)))",
    eb, (long) line);

  return edit_dispatch (expr);
}

/* ── project_grep ─────────────────────────────────────────────────── */

static McpToolResult *
handle_project_grep (McpServer *s, const gchar *n,
                     JsonObject *a, gpointer u)
{
  const gchar *regexp, *directory, *file_glob;
  g_autofree gchar *er = NULL, *ed = NULL, *eg = NULL;
  g_autofree gchar *dir_form = NULL, *include = NULL, *expr = NULL;

  (void) s; (void) n; (void) u;

  regexp = json_object_get_string_member (a, "regexp");
  if (regexp == NULL)
    return edit_error ("Missing required argument: regexp");
  directory = json_object_get_string_member (a, "directory");
  file_glob = json_object_get_string_member (a, "file_glob");

  er = g_strescape (regexp, NULL);

  if (directory != NULL)
    {
      ed = g_strescape (directory, NULL);
      dir_form = g_strdup_printf ("\"%s\"", ed);
    }
  else
    dir_form = g_strdup ("default-directory");

  if (file_glob != NULL)
    {
      eg = g_strescape (file_glob, NULL);
      include = g_strdup_printf (" \"--include=%s\"", eg);
    }
  else
    include = g_strdup ("");

  expr = g_strdup_printf (
    "(with-temp-buffer"
    "  (let ((default-directory %s))"
    "    (call-process \"grep\" nil t nil"
    "                  \"-rIn\" \"--exclude-dir=.git\"%s"
    "                  \"-e\" \"%s\" \".\")"
    "    (let ((lines (split-string (buffer-string) \"\\n\" t)))"
    "      (if lines"
    "          (mapconcat #'identity (seq-take lines 200) \"\\n\")"
    "        \"(no matches)\"))))",
    dir_form, include, er);

  return edit_dispatch (expr);
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_edit_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* get_org_content */
  tool = mcp_tool_new ("get_org_content",
    "Parse an org-mode buffer into a structured JSON document: "
    "buffer keywords (#+TITLE etc.) plus a nested headline tree with "
    "title, level, todo, priority, tags, scheduled/deadline/closed, "
    "property drawers, and body text. match filters entries with "
    "org's agenda match syntax (e.g. \"work+urgent/TODO\").");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"match\":{\"type\":\"string\","
      "\"description\":\"org agenda match string (tags/todo/property "
      "query); empty for all entries\"},"
    "\"max_depth\":{\"type\":\"integer\","
      "\"description\":\"Limit headline depth (0 = unlimited)\"},"
    "\"include_body\":{\"type\":\"boolean\","
      "\"description\":\"Include entry body text (default true)\"},"
    "\"include_properties\":{\"type\":\"boolean\","
      "\"description\":\"Include property drawers (default true)\"}"
    "},\"required\":[\"buffer\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_get_org_content, NULL, NULL);
  g_object_unref (tool);

  /* edit_buffer */
  tool = mcp_tool_new ("edit_buffer",
    "Replace an exact substring in a buffer. old_string must occur "
    "exactly once unless replace_all is true. Errors if not found.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"old_string\":{\"type\":\"string\","
      "\"description\":\"Exact text to replace\"},"
    "\"new_string\":{\"type\":\"string\","
      "\"description\":\"Replacement text\"},"
    "\"replace_all\":{\"type\":\"boolean\","
      "\"description\":\"Replace every occurrence (default false)\"}"
    "},\"required\":[\"buffer\",\"old_string\",\"new_string\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_destructive_hint (tool, FALSE);
  mcp_server_add_tool (server, tool, handle_edit_buffer, NULL, NULL);
  g_object_unref (tool);

  /* replace_in_buffer */
  tool = mcp_tool_new ("replace_in_buffer",
    "Regexp search-and-replace across a whole buffer. Returns the "
    "number of matches replaced.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"regexp\":{\"type\":\"string\","
      "\"description\":\"Emacs regexp to match\"},"
    "\"replacement\":{\"type\":\"string\","
      "\"description\":\"Replacement string (\\\\N backrefs allowed)\"}"
    "},\"required\":[\"buffer\",\"regexp\",\"replacement\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_destructive_hint (tool, FALSE);
  mcp_server_add_tool (server, tool, handle_replace_in_buffer, NULL, NULL);
  g_object_unref (tool);

  /* search_buffer */
  tool = mcp_tool_new ("search_buffer",
    "Search a buffer for a regexp. Returns up to 200 matches as "
    "'LINE: TEXT' lines.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"regexp\":{\"type\":\"string\","
      "\"description\":\"Emacs regexp to match\"}"
    "},\"required\":[\"buffer\",\"regexp\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_search_buffer, NULL, NULL);
  g_object_unref (tool);

  /* goto_line */
  tool = mcp_tool_new ("goto_line",
    "Move point to a 1-based line number in a buffer, updating its "
    "window if one is showing.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Buffer name\"},"
    "\"line\":{\"type\":\"integer\",\"description\":\"1-based line\"}"
    "},\"required\":[\"buffer\",\"line\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_goto_line, NULL, NULL);
  g_object_unref (tool);

  /* project_grep */
  tool = mcp_tool_new ("project_grep",
    "Recursively grep for a pattern under a directory (defaults to "
    "the current default-directory; .git is excluded). Returns up to "
    "200 'file:line:text' hits.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"regexp\":{\"type\":\"string\","
      "\"description\":\"Basic grep regexp\"},"
    "\"directory\":{\"type\":\"string\","
      "\"description\":\"Root directory to search (optional)\"},"
    "\"file_glob\":{\"type\":\"string\","
      "\"description\":\"Restrict to files matching this glob (optional)\"}"
    "},\"required\":[\"regexp\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_project_grep, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
