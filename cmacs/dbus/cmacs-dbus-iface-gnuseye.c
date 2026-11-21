/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-gnuseye.c --- GNU's Eye situational-awareness globe
 * via D-Bus.
 *
 * org.cmacs.Editor1.GnusEye
 *
 * MCP parity: mirrors the gnuseye_* tools in
 * cmacs/mcp/cmacs-mcp-tools-gnuseye.c (sync discipline: adding a tool
 * there requires a matching method here, and vice versa).  The elisp
 * bodies are identical to the MCP handlers'. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_GNUSEYE)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.GnusEye'>"
  "    <method name='Open'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListLayers'>"
  "      <arg type='s' name='layers' direction='out'/>"
  "    </method>"
  "    <method name='ToggleLayer'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='FlyTo'>"
  "      <arg type='d' name='lat' direction='in'/>"
  "      <arg type='d' name='lon' direction='in'/>"
  "      <arg type='d' name='range' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Refresh'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='QueryEntities'>"
  "      <arg type='s' name='kind' direction='in'/>"
  "      <arg type='d' name='west' direction='in'/>"
  "      <arg type='d' name='east' direction='in'/>"
  "      <arg type='d' name='south' direction='in'/>"
  "      <arg type='d' name='north' direction='in'/>"
  "      <arg type='i' name='limit' direction='in'/>"
  "      <arg type='s' name='entities_json' direction='out'/>"
  "    </method>"
  "    <method name='Brief'>"
  "      <arg type='s' name='summary' direction='out'/>"
  "    </method>"
  "    <method name='AddGeofence'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='d' name='lat' direction='in'/>"
  "      <arg type='d' name='lon' direction='in'/>"
  "      <arg type='d' name='radius_km' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Cii'>"
  "      <arg type='s' name='scores_json' direction='out'/>"
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
cmacs_dbus_iface_gnuseye_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_gnuseye_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_GNUSEYE */
