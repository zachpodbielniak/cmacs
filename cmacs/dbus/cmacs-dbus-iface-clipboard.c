/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-clipboard.c --- clipboard operations.
 * Mirrors cmacsgi copy/cut/paste/clip. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Clipboard'>"
  "  <method name='Copy'><arg type='x' name='start' direction='in'/>"
  "    <arg type='x' name='end' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Cut'><arg type='x' name='start' direction='in'/>"
  "    <arg type='x' name='end' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Paste'><arg type='s' name='ack' direction='out'/></method>"
  "  <method name='List'><arg type='s' name='entries' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Copy") == 0 || g_strcmp0 (m, "Cut") == 0)
    {
      gint64 start, end;
      gchar sbuf[24], ebuf[24];
      const gchar *args[2];
      const gchar *fn = g_strcmp0 (m, "Copy") == 0
        ? "kill-ring-save" : "kill-region";
      gchar *tmpl;
      g_variant_get (p, "(xx)", &start, &end);
      g_snprintf (sbuf, sizeof sbuf, "%" G_GINT64_FORMAT, start);
      g_snprintf (ebuf, sizeof ebuf, "%" G_GINT64_FORMAT, end);
      args[0] = sbuf; args[1] = ebuf;
      tmpl = g_strdup_printf (
        "(progn (%s %%s %%s) \"ok\")", fn);
      cmacs_dbus_eval_to_reply (iv, tmpl, args, 2);
      g_free (tmpl);
    }
  else if (g_strcmp0 (m, "Paste") == 0)
    cmacs_dbus_eval_to_reply (iv, "(progn (yank) \"ok\")", NULL, 0);
  else if (g_strcmp0 (m, "List") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(mapconcat (lambda (s) (substring s 0 (min 80 (length s))))"
      " kill-ring \"|||\")", NULL, 0);
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_clipboard_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_clipboard_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
