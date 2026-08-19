/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-dbexplorer.c --- database explorer surface via D-Bus.
 *
 * org.cmacs.Editor1.DbExplorer
 *
 * MCP parity: mirrors db_connections / db_connect / db_disconnect /
 * db_query / db_execute / db_tables / db_columns / db_export in
 * cmacs/mcp/cmacs-mcp-tools-dbexplorer.c, and the `db' command group in
 * cmacs/emacsctl/ctl-cmd-subsys.c (sync discipline: adding a tool there
 * requires a matching method here and an emacsctl row, and vice versa).
 * The elisp bodies are identical to the MCP handlers'.
 *
 * Query and QueryLimited are one MCP tool split in two, because D-Bus
 * has no optional argument: the plain form takes the configured row
 * cap, the limited form names one.
 *
 * A D-Bus caller gets no more trust than an MCP one.  The bus is
 * reachable by anything in the session -- a script, a portal, another
 * agent's bridge -- so connections are still selected by saved name
 * rather than by URL, identifiers are still whitelisted, and free-form
 * strings are still escaped before they reach a Lisp reader.
 *
 * Every handler routes through the Elisp dispatch path, so a D-Bus
 * caller drives the same model as the explorer buffer a human sees. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_DBEXPLORER)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.DbExplorer'>"
  "    <method name='Connections'>"
  "      <arg type='s' name='connections' direction='out'/>"
  "    </method>"
  "    <method name='Connect'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='Disconnect'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='Query'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='sql' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='QueryLimited'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='sql' direction='in'/>"
  "      <arg type='i' name='max_rows' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Execute'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='sql' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Tables'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='schema' direction='in'/>"
  "      <arg type='s' name='tables' direction='out'/>"
  "    </method>"
  "    <method name='Columns'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='table' direction='in'/>"
  "      <arg type='s' name='schema' direction='in'/>"
  "      <arg type='s' name='columns' direction='out'/>"
  "    </method>"
  "    <method name='Export'>"
  "      <arg type='s' name='connection' direction='in'/>"
  "      <arg type='s' name='sql' direction='in'/>"
  "      <arg type='s' name='format' direction='in'/>"
  "      <arg type='s' name='path' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* A connection is named, never described.  The name selects one of the
 * connections an operator already saved, so a caller cannot hand cmacs
 * a URL -- and with it a host and credentials -- of its own choosing.
 * Same regexp the MCP tools use. */
static gboolean
valid_connection_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  return g_regex_match_simple ("^[A-Za-z0-9._-]+$", s, 0, 0);
}

/* Table and schema names reach the database as identifiers, where Lisp
 * string escaping buys nothing --- so they are whitelisted to the shape
 * an unquoted SQL identifier may take.  Quoted identifiers are refused
 * rather than half-handled. */
static gboolean
valid_identifier (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  return g_regex_match_simple ("^[A-Za-z_][A-Za-z0-9_$]*$", s, 0, 0);
}

/* Export formats name a registered exporter, so they are whitelisted
 * for the same reason calculator names are. */
static gboolean
valid_format_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  return g_regex_match_simple ("^[a-z][a-z0-9-]*$", s, 0, 0);
}

/* Evaluate EXPR and reply with the raw string result.  Consumes EXPR. */
static void
eval_to_reply (GDBusMethodInvocation *iv, gchar *expr)
{
  gchar *result;
  GError *err = NULL;

  result = cmacs_dispatch_eval_string (expr, &err);
  g_free (expr);
  if (result == NULL)
    {
      cmacs_dbus_return_gerror (iv, err);
      return;
    }
  g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", result));
  g_free (result);
}

/* Fail the call with MESSAGE.  Returns FALSE so a validation chain can
 * read as `if (!check (iv, ...)) return;'. */
static gboolean
reject (GDBusMethodInvocation *iv, const gchar *message)
{
  g_dbus_method_invocation_return_dbus_error (
    iv, "org.cmacs.Editor1.Error", message);
  return FALSE;
}

/* Guard shared by every method: the connection must name something an
 * operator saved. */
static gboolean
check_connection (GDBusMethodInvocation *iv, const gchar *conn)
{
  if (valid_connection_name (conn))
    return TRUE;
  return reject (iv,
                 "connection must be a saved connection name"
                 " ([A-Za-z0-9._-]+); connection URLs are not accepted");
}

/* Build the query form.  MAX_ROWS above zero names a row cap; anything
 * else leaves the argument off so the model applies its default. */
static gchar *
build_query_elisp (const gchar *conn, const gchar *sql_q, gint max_rows)
{
  if (max_rows > 0)
    return g_strdup_printf (
      "(progn (require 'cmacs-dbexplorer-tools)"
      " (condition-case e"
      "  (cmacs-dbexplorer-tool-query \"%s\" \"%s\" %d)"
      "  (error (format \"error: %%s\" (error-message-string e)))))",
      conn, sql_q, max_rows);
  return g_strdup_printf (
    "(progn (require 'cmacs-dbexplorer-tools)"
    " (condition-case e (cmacs-dbexplorer-tool-query \"%s\" \"%s\")"
    "  (error (format \"error: %%s\" (error-message-string e)))))",
    conn, sql_q);
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Connections") == 0)
    {
      eval_to_reply (iv, g_strdup (
        "(progn (require 'cmacs-dbexplorer-tools)"
        " (condition-case e (cmacs-dbexplorer-tool-connections)"
        "  (error (format \"error: %s\" (error-message-string e)))))"));
    }
  else if (g_strcmp0 (m, "Connect") == 0)
    {
      const gchar *conn;

      g_variant_get (p, "(&s)", &conn);
      if (!check_connection (iv, conn))
        return;

      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-dbexplorer-tools)"
        " (condition-case e (cmacs-dbexplorer-tool-connect \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        conn));
    }
  else if (g_strcmp0 (m, "Disconnect") == 0)
    {
      const gchar *conn;

      g_variant_get (p, "(&s)", &conn);
      if (!check_connection (iv, conn))
        return;

      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-dbexplorer-tools)"
        " (condition-case e (cmacs-dbexplorer-tool-disconnect \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        conn));
    }
  else if (g_strcmp0 (m, "Query") == 0
           || g_strcmp0 (m, "QueryLimited") == 0)
    {
      const gchar *conn, *sql;
      gint max_rows = 0;
      gchar *sql_q;

      if (g_strcmp0 (m, "QueryLimited") == 0)
        g_variant_get (p, "(&s&si)", &conn, &sql, &max_rows);
      else
        g_variant_get (p, "(&s&s)", &conn, &sql);

      if (!check_connection (iv, conn))
        return;
      if (*sql == '\0')
        {
          reject (iv, "missing sql");
          return;
        }

      /* No write path here either: the elisp entry point classifies the
         statement and refuses one that is not a read, so Query cannot
         be talked into an UPDATE. */
      sql_q = cmacs_dbus_lisp_escape (sql);
      eval_to_reply (iv, build_query_elisp (conn, sql_q, max_rows));
      g_free (sql_q);
    }
  else if (g_strcmp0 (m, "Execute") == 0)
    {
      const gchar *conn, *sql;
      gchar *sql_q;

      g_variant_get (p, "(&s&s)", &conn, &sql);
      if (!check_connection (iv, conn))
        return;
      if (*sql == '\0')
        {
          reject (iv, "missing sql");
          return;
        }

      sql_q = cmacs_dbus_lisp_escape (sql);
      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-dbexplorer-tools)"
        " (condition-case e (cmacs-dbexplorer-tool-execute \"%s\" \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        conn, sql_q));
      g_free (sql_q);
    }
  else if (g_strcmp0 (m, "Tables") == 0)
    {
      const gchar *conn, *schema;

      g_variant_get (p, "(&s&s)", &conn, &schema);
      if (!check_connection (iv, conn))
        return;

      /* An empty schema means "the connection's default", so only a
         non-empty one has to survive the identifier whitelist. */
      if (*schema == '\0')
        eval_to_reply (iv, g_strdup_printf (
          "(progn (require 'cmacs-dbexplorer-tools)"
          " (condition-case e (cmacs-dbexplorer-tool-tables \"%s\")"
          "  (error (format \"error: %%s\" (error-message-string e)))))",
          conn));
      else if (!valid_identifier (schema))
        reject (iv,
                "schema must be an unquoted SQL identifier"
                " ([A-Za-z_][A-Za-z0-9_$]*)");
      else
        eval_to_reply (iv, g_strdup_printf (
          "(progn (require 'cmacs-dbexplorer-tools)"
          " (condition-case e (cmacs-dbexplorer-tool-tables \"%s\" \"%s\")"
          "  (error (format \"error: %%s\" (error-message-string e)))))",
          conn, schema));
    }
  else if (g_strcmp0 (m, "Columns") == 0)
    {
      const gchar *conn, *table, *schema;

      g_variant_get (p, "(&s&s&s)", &conn, &table, &schema);
      if (!check_connection (iv, conn))
        return;
      if (!valid_identifier (table))
        {
          reject (iv,
                  "table must be an unquoted SQL identifier"
                  " ([A-Za-z_][A-Za-z0-9_$]*)");
          return;
        }

      if (*schema == '\0')
        eval_to_reply (iv, g_strdup_printf (
          "(progn (require 'cmacs-dbexplorer-tools)"
          " (condition-case e (cmacs-dbexplorer-tool-columns \"%s\" \"%s\")"
          "  (error (format \"error: %%s\" (error-message-string e)))))",
          conn, table));
      else if (!valid_identifier (schema))
        reject (iv,
                "schema must be an unquoted SQL identifier"
                " ([A-Za-z_][A-Za-z0-9_$]*)");
      else
        eval_to_reply (iv, g_strdup_printf (
          "(progn (require 'cmacs-dbexplorer-tools)"
          " (condition-case e"
          "  (cmacs-dbexplorer-tool-columns \"%s\" \"%s\" \"%s\")"
          "  (error (format \"error: %%s\" (error-message-string e)))))",
          conn, table, schema));
    }
  else if (g_strcmp0 (m, "Export") == 0)
    {
      const gchar *conn, *sql, *format, *path;
      gchar *sql_q, *path_q;

      g_variant_get (p, "(&s&s&s&s)", &conn, &sql, &format, &path);
      if (!check_connection (iv, conn))
        return;
      if (*sql == '\0')
        {
          reject (iv, "missing sql");
          return;
        }
      if (!valid_format_name (format))
        {
          reject (iv,
                  "format must be a registered exporter name"
                  " ([a-z][a-z0-9-]*), e.g. csv");
          return;
        }
      if (*path == '\0')
        {
          reject (iv, "missing path");
          return;
        }

      sql_q = cmacs_dbus_lisp_escape (sql);
      path_q = cmacs_dbus_lisp_escape (path);
      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-dbexplorer-tools)"
        " (condition-case e"
        "  (cmacs-dbexplorer-tool-export \"%s\" \"%s\" \"%s\" \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        conn, sql_q, format, path_q));
      g_free (sql_q);
      g_free (path_q);
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_dbexplorer_register (GDBusConnection *conn,
                                      const gchar *path, GError **error)
{
  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_dbexplorer_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_DBEXPLORER */
