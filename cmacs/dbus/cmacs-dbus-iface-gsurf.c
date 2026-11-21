/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-gsurf.c --- gsurf embedded web browser via D-Bus.
 *
 * org.cmacs.Editor1.Gsurf
 *
 * Every method here is a row of cmacs-dbus-forward-table.h: it is
 * served by the gsurf_* registry tool of the same capability
 * (lisp/cmacs/cmacs-gsurf-tools.el), through cmacs-dbus-forward.c, and
 * so inherits what the tool has -- the redaction of URLs, titles and
 * page text, argument validation, the confirmation policy, and an
 * answer that is sent later for the asynchronous ones (Snapshot,
 * PrintPdf).  This file keeps the interface: names and signatures.
 *
 * Convention: an empty BUFFER argument means "the most recent gsurf
 * buffer"; the table's argument map leaves it out of the call. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_GSURF)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Gsurf'>"
  "    <method name='Open'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Navigate'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Back'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Forward'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Reload'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Stop'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GetUri'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='uri' direction='out'/>"
  "    </method>"
  "    <method name='GetTitle'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='title' direction='out'/>"
  "    </method>"
  "    <method name='Current'>"
  "      <arg type='s' name='info' direction='out'/>"
  "    </method>"
  "    <method name='List'>"
  "      <arg type='s' name='buffers' direction='out'/>"
  "    </method>"
  "    <method name='ModulesList'>"
  "      <arg type='s' name='modules' direction='out'/>"
  "    </method>"
  "    <method name='EvalJs'>"
  "      <arg type='s' name='script' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='SetZoom'>"
  "      <arg type='d' name='level' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='LiteOpen'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ExtractText'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='text' direction='out'/>"
  "    </method>"
  "    <method name='DownloadList'>"
  "      <arg type='s' name='downloads' direction='out'/>"
  "    </method>"
  "    <method name='DownloadCancel'>"
  "      <arg type='x' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Snapshot'>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='b' name='full_page' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='PrintPdf'>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='PermissionPolicy'>"
  "      <arg type='s' name='origin' direction='in'/>"
  "      <arg type='s' name='type' direction='in'/>"
  "      <arg type='s' name='verdict' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Click'>"
  "      <arg type='d' name='x' direction='in'/>"
  "      <arg type='d' name='y' direction='in'/>"
  "      <arg type='i' name='button' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='TypeText'>"
  "      <arg type='s' name='text' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='PressKey'>"
  "      <arg type='s' name='key' direction='in'/>"
  "      <arg type='s' name='modifiers' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ClickElement'>"
  "      <arg type='s' name='selector' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='SetCookie'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='value' direction='in'/>"
  "      <arg type='s' name='domain' direction='in'/>"
  "      <arg type='s' name='path' direction='in'/>"
  "      <arg type='b' name='secure' direction='in'/>"
  "      <arg type='b' name='http_only' direction='in'/>"
  "      <arg type='x' name='expires' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ToggleModule'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='enabled' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='RunAction'>"
  "      <arg type='s' name='action' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListActions'>"
  "      <arg type='s' name='actions' direction='out'/>"
  "    </method>"
  "    <method name='ListContainers'>"
  "      <arg type='s' name='containers' direction='out'/>"
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
cmacs_dbus_iface_gsurf_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_gsurf_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_GSURF */
