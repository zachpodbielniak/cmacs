/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-vc.c --- VC operations via D-Bus.
 * Mirrors cmacsgi's vc {status,diff,log,blame}. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.VC'>"
  "  <method name='Status'>"
  "    <arg type='s' name='output' direction='out'/></method>"
  "  <method name='Diff'>"
  "    <arg type='s' name='file' direction='in'/>"
  "    <arg type='s' name='output' direction='out'/></method>"
  "  <method name='Log'>"
  "    <arg type='i' name='count' direction='in'/>"
  "    <arg type='s' name='file' direction='in'/>"
  "    <arg type='s' name='output' direction='out'/></method>"
  "  <method name='Blame'>"
  "    <arg type='s' name='file' direction='in'/>"
  "    <arg type='s' name='output' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Status") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(let ((root (vc-root-dir)))"
      " (if root"
      "  (with-temp-buffer"
      "   (let ((default-directory root))"
      "    (call-process \"git\" nil t nil \"status\" \"--porcelain\" \"-b\"))"
      "   (buffer-string))"
      "  \"not in a VC-controlled directory\"))",
      NULL, 0);
  else if (g_strcmp0 (m, "Diff") == 0)
    {
      const gchar *file;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &file);
      args[0] = file;
      if (file && *file)
        cmacs_dbus_eval_to_reply (iv,
          "(with-temp-buffer"
          " (call-process \"git\" nil t nil \"diff\" \"--no-color\" \"%s\")"
          " (buffer-string))", args, 1);
      else
        cmacs_dbus_eval_to_reply (iv,
          "(with-temp-buffer"
          " (let ((default-directory (or (vc-root-dir) default-directory)))"
          "  (call-process \"git\" nil t nil \"diff\" \"--no-color\"))"
          " (buffer-string))", NULL, 0);
    }
  else if (g_strcmp0 (m, "Log") == 0)
    {
      gint32 n;
      const gchar *file;
      gchar nbuf[16];
      const gchar *args[2];
      g_variant_get (p, "(i&s)", &n, &file);
      g_snprintf (nbuf, sizeof nbuf, "%d", n > 0 ? n : 20);
      args[0] = nbuf;
      args[1] = file;
      if (file && *file)
        cmacs_dbus_eval_to_reply (iv,
          "(with-temp-buffer"
          " (call-process \"git\" nil t nil \"log\" \"--oneline\" \"-n\" \"%s\" \"--\" \"%s\")"
          " (buffer-string))", args, 2);
      else
        cmacs_dbus_eval_to_reply (iv,
          "(with-temp-buffer"
          " (let ((default-directory (or (vc-root-dir) default-directory)))"
          "  (call-process \"git\" nil t nil \"log\" \"--oneline\" \"-n\" \"%s\"))"
          " (buffer-string))", args, 1);
    }
  else if (g_strcmp0 (m, "Blame") == 0)
    {
      const gchar *file;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &file);
      args[0] = file;
      cmacs_dbus_eval_to_reply (iv,
        "(with-temp-buffer"
        " (call-process \"git\" nil t nil \"blame\" \"--\" \"%s\")"
        " (buffer-string))", args, 1);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_vc_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_vc_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
