/*
 * cmacs-mcp-tools-dbexplorer.c — MCP tools for the database explorer
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes the database explorer as MCP tools so an external agent can
 * read and change data through a live cmacs:
 *   - db_connections: saved and live connections
 *   - db_connect / db_disconnect: bring a saved connection up or down
 *   - db_query:      run a read, returning columns and rows
 *   - db_execute:    run a write, returning the rows affected
 *   - db_tables:     tables and views in a schema
 *   - db_columns:    one table's columns
 *   - db_export:     write a query's result to a file
 *
 * D-Bus parity: org.cmacs.Editor1.DbExplorer in
 * cmacs/dbus/cmacs-dbus-iface-dbexplorer.c, and the `db' command group
 * in cmacs/emacsctl/ctl-cmd-subsys.c (sync discipline: adding a tool
 * here requires a matching method and an emacsctl row there, and vice
 * versa).
 *
 * All handlers route through the Elisp dispatch path, so a tool call
 * runs the same model -- the same connection registry, the same
 * read/write classification, the same hooks -- as the explorer buffer
 * a human is looking at.
 *
 * The security posture of this file is the reason it exists.  A caller
 * here is untrusted: it names a connection that an operator already
 * saved, never a URL of its own, so it cannot point cmacs at a database
 * with credentials it chose; identifiers are whitelisted rather than
 * escaped, because they are spliced where escaping does not apply; and
 * every free-form string is escaped before it reaches a Lisp reader.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP
#ifdef HAVE_CMACS_DBEXPLORER

#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <mcp.h>
#include <glib.h>
#include <string.h>

/* Ceiling on the characters one tool call may return.  A single SELECT
 * can produce more text than an agent can afford to read, and the
 * caller pays for every character of it, so the reply is cut here with
 * a marker rather than shortened silently -- a quietly clipped result
 * would be read as the whole answer.  Callers that want more should
 * narrow the query or page it with max_rows. */
#define DBEXPLORER_MAX_RESULT_CHARS (40000)

/* Escape a string for interpolation into a quoted Lisp string.  SQL and
 * file paths arrive verbatim from an external agent, so this is the
 * boundary that keeps them data instead of code: without it a `"' in the
 * argument would close the string and the rest would be read as Lisp. */
static gchar *
escape_for_lisp (const gchar *s)
{
  GString *out;
  const gchar *p;

  if (s == NULL) return g_strdup ("");
  out = g_string_sized_new (strlen (s) + 8);
  for (p = s; *p; p++)
    {
      if (*p == '\\' || *p == '"')
        g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  return g_string_free (out, FALSE);
}

/* A connection is named, never described.  The name selects one of the
 * connections an operator already saved, so a caller cannot hand cmacs
 * a URL -- and with it a host and credentials -- of its own choosing.
 * The charset is deliberately narrower than the escape above needs: it
 * keeps the value legible in error text and in the explorer's buffer
 * names, both of which a human reads to decide what a tool did. */
static gboolean
valid_connection_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  return g_regex_match_simple ("^[A-Za-z0-9._-]+$", s, 0, 0);
}

/* Table and schema names reach the database as identifiers, where Lisp
 * string escaping buys nothing -- so they are whitelisted to the shape
 * an unquoted SQL identifier may take.  Quoted identifiers ("odd name",
 * `odd name`) are refused rather than half-handled: accepting the
 * opening quote without owning the quoting rules of three dialects is
 * how an injection gets in. */
static gboolean
valid_identifier (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  return g_regex_match_simple ("^[A-Za-z_][A-Za-z0-9_$]*$", s, 0, 0);
}

/* Export formats name a registered exporter, so they are whitelisted
 * for the same reason calculator names are: the value is meant to be a
 * short symbol-shaped token, and anything else is a mistake worth
 * reporting instead of forwarding. */
static gboolean
valid_format_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  return g_regex_match_simple ("^[a-z][a-z0-9-]*$", s, 0, 0);
}

/* Build a one-line error result naming the offending tool. */
static McpToolResult *
error_result (const gchar *message)
{
  McpToolResult *r = mcp_tool_result_new (TRUE);

  mcp_tool_result_add_text (r, message);
  return r;
}

/* Run EXPR through the Elisp dispatcher and wrap the reply as a tool
 * result, capped at DBEXPLORER_MAX_RESULT_CHARS.  ERRLABEL names the
 * tool in the failure message. */
static McpToolResult *
eval_to_result (const gchar *expr, const gchar *errlabel)
{
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r;
  gsize len;

  if (res == NULL)
    return error_result (err ? err->message : errlabel);

  len = strlen (res);
  if (len <= DBEXPLORER_MAX_RESULT_CHARS)
    {
      r = mcp_tool_result_new (FALSE);
      mcp_tool_result_add_text (r, res);
      return r;
    }

  {
    g_autofree gchar *head = g_strndup (res, DBEXPLORER_MAX_RESULT_CHARS);
    g_autofree gchar *text = NULL;
    gchar *bad = NULL;

    /* The cut lands on a byte boundary, which may be mid-character in a
       column holding non-ASCII text; drop the partial character so the
       reply stays valid UTF-8. */
    if (!g_utf8_validate (head, -1, (const gchar **) &bad))
      *bad = '\0';

    text = g_strdup_printf (
      "%s\n\n[truncated: %" G_GSIZE_FORMAT " of %" G_GSIZE_FORMAT
      " characters shown; narrow the query or lower max_rows]",
      head, strlen (head), len);
    r = mcp_tool_result_new (FALSE);
    mcp_tool_result_add_text (r, text);
    return r;
  }
}

/* Fetch a required string argument, or NULL. */
static const gchar *
arg_string (JsonObject *arguments, const gchar *key)
{
  return json_object_has_member (arguments, key)
    ? json_object_get_string_member (arguments, key) : NULL;
}

static McpToolResult *
handle_db_connections (McpServer *server, const gchar *name,
                       JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) arguments; (void) user_data;

  return eval_to_result (
    "(progn (require 'cmacs-dbexplorer-tools)"
    " (condition-case e (cmacs-dbexplorer-tool-connections)"
    "  (error (format \"error: %s\" (error-message-string e)))))",
    "db_connections failed");
}

static McpToolResult *
handle_db_connect (McpServer *server, const gchar *name,
                   JsonObject *arguments, gpointer user_data)
{
  const gchar *conn = arg_string (arguments, "connection");
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (!valid_connection_name (conn))
    return error_result (
      "db_connect: 'connection' must be a saved connection name"
      " ([A-Za-z0-9._-]+); connection URLs are not accepted");

  lisp = g_strdup_printf (
    "(progn (require 'cmacs-dbexplorer-tools)"
    " (condition-case e (cmacs-dbexplorer-tool-connect \"%s\")"
    "  (error (format \"error: %%s\" (error-message-string e)))))",
    conn);
  return eval_to_result (lisp, "db_connect failed");
}

static McpToolResult *
handle_db_disconnect (McpServer *server, const gchar *name,
                      JsonObject *arguments, gpointer user_data)
{
  const gchar *conn = arg_string (arguments, "connection");
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (!valid_connection_name (conn))
    return error_result (
      "db_disconnect: 'connection' must be a saved connection name"
      " ([A-Za-z0-9._-]+)");

  lisp = g_strdup_printf (
    "(progn (require 'cmacs-dbexplorer-tools)"
    " (condition-case e (cmacs-dbexplorer-tool-disconnect \"%s\")"
    "  (error (format \"error: %%s\" (error-message-string e)))))",
    conn);
  return eval_to_result (lisp, "db_disconnect failed");
}

static McpToolResult *
handle_db_query (McpServer *server, const gchar *name,
                 JsonObject *arguments, gpointer user_data)
{
  const gchar *conn = arg_string (arguments, "connection");
  const gchar *sql = arg_string (arguments, "sql");
  gint64 max_rows = json_object_has_member (arguments, "max_rows")
    ? json_object_get_int_member (arguments, "max_rows") : 0;
  g_autofree gchar *sql_esc = NULL;
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (!valid_connection_name (conn))
    return error_result (
      "db_query: 'connection' must be a saved connection name"
      " ([A-Za-z0-9._-]+); connection URLs are not accepted");
  if (sql == NULL || *sql == '\0')
    return error_result ("db_query: missing 'sql'");

  sql_esc = escape_for_lisp (sql);
  /* There is deliberately no write path here: the Elisp entry point
     classifies the statement and refuses one that is not a read, so a
     caller cannot reach an UPDATE through the tool hinted read-only. */
  if (max_rows > 0)
    lisp = g_strdup_printf (
      "(progn (require 'cmacs-dbexplorer-tools)"
      " (condition-case e"
      "  (cmacs-dbexplorer-tool-query \"%s\" \"%s\" %" G_GINT64_FORMAT ")"
      "  (error (format \"error: %%s\" (error-message-string e)))))",
      conn, sql_esc, max_rows);
  else
    lisp = g_strdup_printf (
      "(progn (require 'cmacs-dbexplorer-tools)"
      " (condition-case e (cmacs-dbexplorer-tool-query \"%s\" \"%s\")"
      "  (error (format \"error: %%s\" (error-message-string e)))))",
      conn, sql_esc);
  return eval_to_result (lisp, "db_query failed");
}

static McpToolResult *
handle_db_execute (McpServer *server, const gchar *name,
                   JsonObject *arguments, gpointer user_data)
{
  const gchar *conn = arg_string (arguments, "connection");
  const gchar *sql = arg_string (arguments, "sql");
  g_autofree gchar *sql_esc = NULL;
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (!valid_connection_name (conn))
    return error_result (
      "db_execute: 'connection' must be a saved connection name"
      " ([A-Za-z0-9._-]+); connection URLs are not accepted");
  if (sql == NULL || *sql == '\0')
    return error_result ("db_execute: missing 'sql'");

  sql_esc = escape_for_lisp (sql);
  lisp = g_strdup_printf (
    "(progn (require 'cmacs-dbexplorer-tools)"
    " (condition-case e (cmacs-dbexplorer-tool-execute \"%s\" \"%s\")"
    "  (error (format \"error: %%s\" (error-message-string e)))))",
    conn, sql_esc);
  return eval_to_result (lisp, "db_execute failed");
}

static McpToolResult *
handle_db_tables (McpServer *server, const gchar *name,
                  JsonObject *arguments, gpointer user_data)
{
  const gchar *conn = arg_string (arguments, "connection");
  const gchar *schema = arg_string (arguments, "schema");
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (!valid_connection_name (conn))
    return error_result (
      "db_tables: 'connection' must be a saved connection name"
      " ([A-Za-z0-9._-]+)");

  if (schema != NULL && *schema != '\0')
    {
      if (!valid_identifier (schema))
        return error_result (
          "db_tables: 'schema' must be an unquoted SQL identifier"
          " ([A-Za-z_][A-Za-z0-9_$]*)");
      lisp = g_strdup_printf (
        "(progn (require 'cmacs-dbexplorer-tools)"
        " (condition-case e (cmacs-dbexplorer-tool-tables \"%s\" \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        conn, schema);
    }
  else
    lisp = g_strdup_printf (
      "(progn (require 'cmacs-dbexplorer-tools)"
      " (condition-case e (cmacs-dbexplorer-tool-tables \"%s\")"
      "  (error (format \"error: %%s\" (error-message-string e)))))",
      conn);
  return eval_to_result (lisp, "db_tables failed");
}

static McpToolResult *
handle_db_columns (McpServer *server, const gchar *name,
                   JsonObject *arguments, gpointer user_data)
{
  const gchar *conn = arg_string (arguments, "connection");
  const gchar *table = arg_string (arguments, "table");
  const gchar *schema = arg_string (arguments, "schema");
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (!valid_connection_name (conn))
    return error_result (
      "db_columns: 'connection' must be a saved connection name"
      " ([A-Za-z0-9._-]+)");
  if (!valid_identifier (table))
    return error_result (
      "db_columns: 'table' must be an unquoted SQL identifier"
      " ([A-Za-z_][A-Za-z0-9_$]*)");

  if (schema != NULL && *schema != '\0')
    {
      if (!valid_identifier (schema))
        return error_result (
          "db_columns: 'schema' must be an unquoted SQL identifier"
          " ([A-Za-z_][A-Za-z0-9_$]*)");
      lisp = g_strdup_printf (
        "(progn (require 'cmacs-dbexplorer-tools)"
        " (condition-case e"
        "  (cmacs-dbexplorer-tool-columns \"%s\" \"%s\" \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        conn, table, schema);
    }
  else
    lisp = g_strdup_printf (
      "(progn (require 'cmacs-dbexplorer-tools)"
      " (condition-case e (cmacs-dbexplorer-tool-columns \"%s\" \"%s\")"
      "  (error (format \"error: %%s\" (error-message-string e)))))",
      conn, table);
  return eval_to_result (lisp, "db_columns failed");
}

static McpToolResult *
handle_db_export (McpServer *server, const gchar *name,
                  JsonObject *arguments, gpointer user_data)
{
  const gchar *conn = arg_string (arguments, "connection");
  const gchar *sql = arg_string (arguments, "sql");
  const gchar *format = arg_string (arguments, "format");
  const gchar *path = arg_string (arguments, "path");
  g_autofree gchar *sql_esc = NULL;
  g_autofree gchar *path_esc = NULL;
  g_autofree gchar *lisp = NULL;

  (void) server; (void) name; (void) user_data;

  if (!valid_connection_name (conn))
    return error_result (
      "db_export: 'connection' must be a saved connection name"
      " ([A-Za-z0-9._-]+)");
  if (sql == NULL || *sql == '\0')
    return error_result ("db_export: missing 'sql'");
  if (!valid_format_name (format))
    return error_result (
      "db_export: 'format' must be a registered exporter name"
      " ([a-z][a-z0-9-]*), e.g. csv");
  if (path == NULL || *path == '\0')
    return error_result ("db_export: missing 'path'");

  sql_esc = escape_for_lisp (sql);
  path_esc = escape_for_lisp (path);
  lisp = g_strdup_printf (
    "(progn (require 'cmacs-dbexplorer-tools)"
    " (condition-case e"
    "  (cmacs-dbexplorer-tool-export \"%s\" \"%s\" \"%s\" \"%s\")"
    "  (error (format \"error: %%s\" (error-message-string e)))))",
    conn, sql_esc, format, path_esc);
  return eval_to_result (lisp, "db_export failed");
}

void
cmacs_mcp_tools_dbexplorer_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("db_connections",
    "List the database connections this cmacs knows: the saved ones and "
    "which of them are currently open.  Returns a JSON array of "
    "{name, dialect, state, read_only}.  Every other db_* tool takes one "
    "of these names -- there is no way to open a database by URL.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{},\"required\":[]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_db_connections, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("db_connect",
    "Open the saved connection named CONNECTION, so queries can run "
    "against it.  Names come from db_connections; a connection URL is "
    "not accepted.  Already-open connections are left alone.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"connection\":{\"type\":\"string\",\"description\":"
    "\"Saved connection name from db_connections\"}"
    "},\"required\":[\"connection\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_db_connect, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("db_disconnect",
    "Close the connection named CONNECTION, releasing its database "
    "handle and dropping its cached schema.  The saved definition "
    "survives, so db_connect brings it back.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"connection\":{\"type\":\"string\",\"description\":"
    "\"Saved connection name from db_connections\"}"
    "},\"required\":[\"connection\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_db_disconnect, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("db_query",
    "Run a read-only SQL statement on CONNECTION and return its result "
    "as JSON {columns, rows, truncated, row_count}.  A statement that "
    "writes is refused here -- use db_execute for that.  MAX_ROWS caps "
    "the rows fetched; the reply is also cut at a fixed character "
    "budget, so prefer a narrow SELECT over 'SELECT *' on a big table.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"connection\":{\"type\":\"string\",\"description\":"
    "\"Saved connection name from db_connections\"},"
    "\"sql\":{\"type\":\"string\",\"description\":"
    "\"Read-only statement, e.g. SELECT id, name FROM users LIMIT 20\"},"
    "\"max_rows\":{\"type\":\"integer\",\"description\":"
    "\"Maximum rows to fetch; omit for the configured default\"}"
    "},\"required\":[\"connection\",\"sql\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_db_query, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("db_execute",
    "Run a writing SQL statement (INSERT/UPDATE/DELETE/DDL) on "
    "CONNECTION and return JSON {rows_affected, last_insert_rowid}.  "
    "This changes data: a connection marked read-only refuses it.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"connection\":{\"type\":\"string\",\"description\":"
    "\"Saved connection name from db_connections\"},"
    "\"sql\":{\"type\":\"string\",\"description\":"
    "\"Statement to execute, e.g. UPDATE users SET name = 'x' WHERE id = 1\"}"
    "},\"required\":[\"connection\",\"sql\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_db_execute, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("db_tables",
    "List the tables and views on CONNECTION as a JSON array of "
    "{name, kind, schema}, optionally restricted to one SCHEMA.  Start "
    "here before writing a query against an unfamiliar database.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"connection\":{\"type\":\"string\",\"description\":"
    "\"Saved connection name from db_connections\"},"
    "\"schema\":{\"type\":\"string\",\"description\":"
    "\"Schema to restrict to; omit for the connection's default\"}"
    "},\"required\":[\"connection\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_db_tables, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("db_columns",
    "Describe one table's columns on CONNECTION: name, type, "
    "nullability, default and primary-key membership, as a JSON array.  "
    "TABLE and SCHEMA must be plain unquoted identifiers.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"connection\":{\"type\":\"string\",\"description\":"
    "\"Saved connection name from db_connections\"},"
    "\"table\":{\"type\":\"string\",\"description\":"
    "\"Table or view name, e.g. users\"},"
    "\"schema\":{\"type\":\"string\",\"description\":"
    "\"Schema the table lives in; omit for the default\"}"
    "},\"required\":[\"connection\",\"table\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_db_columns, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("db_export",
    "Run SQL on CONNECTION and write the whole result to PATH in "
    "FORMAT (csv, json, org, ...), returning a status line rather than "
    "the data.  Use this instead of db_query when the result is too "
    "large to read back, or when it is wanted on disk.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"connection\":{\"type\":\"string\",\"description\":"
    "\"Saved connection name from db_connections\"},"
    "\"sql\":{\"type\":\"string\",\"description\":"
    "\"Statement whose result is exported\"},"
    "\"format\":{\"type\":\"string\",\"description\":"
    "\"Registered exporter name, e.g. csv\"},"
    "\"path\":{\"type\":\"string\",\"description\":"
    "\"Destination file path\"}"
    "},\"required\":[\"connection\",\"sql\",\"format\",\"path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_db_export, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_DBEXPLORER */
#endif /* HAVE_CMACS_MCP */
