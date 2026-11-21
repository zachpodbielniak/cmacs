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

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  /* Every method of this interface has a row in
     cmacs-dbus-forward-table.h and is served from the capability
     table: there is no per-method code here.  The fallback below is
     for a method added to the XML above without a row or a body.  */
  if (cmacs_dbus_forward (i, m, p, iv))
    return;

  g_dbus_method_invocation_return_dbus_error (
    iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
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
