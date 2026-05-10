/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-nav.c --- point/goto.
 * Mirrors cmacsgi point/goto. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"
#include <gio/gio.h>
#include <stdio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Nav'>"
  "  <method name='Point'>"
  "    <arg type='x' name='line' direction='out'/>"
  "    <arg type='x' name='col' direction='out'/></method>"
  "  <method name='Goto'><arg type='x' name='line' direction='in'/>"
  "    <arg type='x' name='col' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Point") == 0)
    {
      GError *err = NULL;
      gchar *result;
      gint64 line = -1, col = -1;
      result = cmacs_dispatch_eval (
        "(format \"%d %d\" (line-number-at-pos) (current-column))", &err);
      if (result == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      sscanf (result, "\"%" G_GINT64_FORMAT " %" G_GINT64_FORMAT "\"",
              &line, &col);
      g_free (result);
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(xx)", line, col));
    }
  else if (g_strcmp0 (m, "Goto") == 0)
    {
      gint64 line, col;
      gchar lbuf[24], cbuf[24];
      const gchar *args[2];
      g_variant_get (p, "(xx)", &line, &col);
      g_snprintf (lbuf, sizeof lbuf, "%" G_GINT64_FORMAT, line);
      g_snprintf (cbuf, sizeof cbuf, "%" G_GINT64_FORMAT, col);
      args[0] = lbuf; args[1] = cbuf;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (goto-line %s) (move-to-column %s) \"ok\")", args, 2);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_nav_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_nav_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
