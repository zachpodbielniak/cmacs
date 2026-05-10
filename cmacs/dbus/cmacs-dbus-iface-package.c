/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-package.c --- Emacs package management.
 * Mirrors cmacsgi pkg {install,remove,list,refresh}. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Package'>"
  "  <method name='Install'><arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Remove'><arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='List'><arg type='s' name='installed' direction='out'/></method>"
  "  <method name='Refresh'><arg type='s' name='ack' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Install") == 0)
    {
      const gchar *name; const gchar *args[1];
      g_variant_get (p, "(&s)", &name); args[0] = name;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (package-refresh-contents)"
        " (package-install (intern \"%s\")) \"ok\")", args, 1);
    }
  else if (g_strcmp0 (m, "Remove") == 0)
    {
      const gchar *name; const gchar *args[1];
      g_variant_get (p, "(&s)", &name); args[0] = name;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (package-delete"
        " (cadr (assq (intern \"%s\") package-alist))) \"ok\")",
        args, 1);
    }
  else if (g_strcmp0 (m, "List") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(mapconcat (lambda (p) (symbol-name (car p)))"
      " package-alist \"|||\")", NULL, 0);
  else if (g_strcmp0 (m, "Refresh") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(progn (package-refresh-contents) \"ok\")", NULL, 0);
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_package_register (GDBusConnection *conn, const gchar *path,
                                    GError **error)
{
  if (iface_info == NULL) {
    iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
    if (iface_info == NULL) return 0;
  }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_package_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
