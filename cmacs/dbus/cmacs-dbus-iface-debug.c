/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-debug.c --- runtime introspection and debugging
 * via D-Bus.
 *
 * org.cmacs.Editor1.Debug
 *
 * MCP parity: mirrors backtrace / memory_info / list_hooks /
 * describe_mode / profiler_* in cmacs/mcp/cmacs-mcp-tools-debug.c and
 * describe_function / describe_variable / apropos / completions in
 * cmacs-mcp-tools-eval.c (sync discipline: adding a tool there
 * requires a matching method here, and vice versa).  The elisp bodies
 * are identical to the MCP handlers'. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Debug'>"
  "    <method name='Backtrace'>"
  "      <arg type='s' name='trace' direction='out'/>"
  "    </method>"
  "    <method name='MemoryInfo'>"
  "      <arg type='s' name='info' direction='out'/>"
  "    </method>"
  "    <method name='ListHooks'>"
  "      <arg type='s' name='hooks' direction='out'/>"
  "    </method>"
  "    <method name='DescribeMode'>"
  "      <arg type='s' name='modes' direction='out'/>"
  "    </method>"
  "    <method name='DescribeFunction'>"
  "      <arg type='s' name='symbol' direction='in'/>"
  "      <arg type='s' name='doc' direction='out'/>"
  "    </method>"
  "    <method name='DescribeVariable'>"
  "      <arg type='s' name='symbol' direction='in'/>"
  "      <arg type='s' name='doc' direction='out'/>"
  "    </method>"
  "    <method name='Apropos'>"
  "      <arg type='s' name='pattern' direction='in'/>"
  "      <arg type='s' name='symbols' direction='out'/>"
  "    </method>"
  "    <method name='Completions'>"
  "      <arg type='s' name='prefix' direction='in'/>"
  "      <arg type='as' name='candidates' direction='out'/>"
  "    </method>"
  "    <method name='ProfilerStart'>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='ProfilerStop'>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='ProfilerReport'>"
  "      <arg type='s' name='report' direction='out'/>"
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
cmacs_dbus_iface_debug_register (GDBusConnection *conn, const gchar *path,
                                 GError **error)
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
cmacs_dbus_iface_debug_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
