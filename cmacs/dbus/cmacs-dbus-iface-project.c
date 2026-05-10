/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-project.c --- project + build operations.
 * Mirrors cmacsgi's grep / find / project-root / compile / diag. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Project'>"
  "  <method name='Grep'>"
  "    <arg type='s' name='pattern' direction='in'/>"
  "    <arg type='s' name='dir' direction='in'/>"
  "    <arg type='s' name='output' direction='out'/></method>"
  "  <method name='Find'>"
  "    <arg type='s' name='filename' direction='in'/>"
  "    <arg type='s' name='dir' direction='in'/>"
  "    <arg type='s' name='output' direction='out'/></method>"
  "  <method name='Root'>"
  "    <arg type='s' name='root' direction='out'/></method>"
  "  <method name='Compile'>"
  "    <arg type='s' name='command' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='NextError'>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='PrevError'>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Grep") == 0)
    {
      const gchar *pat, *dir;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &pat, &dir);
      args[0] = pat; args[1] = (dir && *dir) ? dir : ".";
      cmacs_dbus_eval_to_reply (iv,
        "(with-temp-buffer"
        " (call-process \"grep\" nil t nil \"-rn\" \"--\" \"%s\" \"%s\")"
        " (buffer-string))", args, 2);
    }
  else if (g_strcmp0 (m, "Find") == 0)
    {
      const gchar *name, *dir;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &name, &dir);
      args[0] = (dir && *dir) ? dir : ".";
      args[1] = name;
      cmacs_dbus_eval_to_reply (iv,
        "(with-temp-buffer"
        " (call-process \"find\" nil t nil \"%s\" \"-name\" \"%s\")"
        " (buffer-string))", args, 2);
    }
  else if (g_strcmp0 (m, "Root") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(or (and (project-current) (project-root (project-current)))"
      "    default-directory)", NULL, 0);
  else if (g_strcmp0 (m, "Compile") == 0)
    {
      const gchar *cmd;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &cmd);
      args[0] = cmd;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (compile \"%s\") \"started\")", args, 1);
    }
  else if (g_strcmp0 (m, "NextError") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(progn (next-error) \"ok\")", NULL, 0);
  else if (g_strcmp0 (m, "PrevError") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(progn (previous-error) \"ok\")", NULL, 0);
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_project_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_project_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
