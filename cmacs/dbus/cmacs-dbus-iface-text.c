/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-text.c --- text editing.
 * Mirrors cmacsgi insert/delete/line/append. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Text'>"
  "  <method name='Insert'><arg type='s' name='text' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Delete'><arg type='x' name='start' direction='in'/>"
  "    <arg type='x' name='end' direction='in'/>"
  "    <arg type='s' name='deleted' direction='out'/></method>"
  "  <method name='Line'><arg type='x' name='n' direction='in'/>"
  "    <arg type='s' name='content' direction='out'/></method>"
  "  <method name='Append'><arg type='s' name='text' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Insert") == 0)
    {
      const gchar *text; const gchar *args[1];
      g_variant_get (p, "(&s)", &text); args[0] = text;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (insert \"%s\") \"ok\")", args, 1);
    }
  else if (g_strcmp0 (m, "Delete") == 0)
    {
      gint64 start, end;
      gchar sbuf[24], ebuf[24];
      const gchar *args[2];
      g_variant_get (p, "(xx)", &start, &end);
      g_snprintf (sbuf, sizeof sbuf, "%" G_GINT64_FORMAT, start);
      g_snprintf (ebuf, sizeof ebuf, "%" G_GINT64_FORMAT, end);
      args[0] = sbuf; args[1] = ebuf;
      cmacs_dbus_eval_to_reply (iv,
        "(let ((s (buffer-substring-no-properties %s %s)))"
        " (delete-region %s %s) s)",
        (const gchar *[]) { sbuf, ebuf, sbuf, ebuf }, 4);
    }
  else if (g_strcmp0 (m, "Line") == 0)
    {
      gint64 n; gchar nbuf[24]; const gchar *args[1];
      g_variant_get (p, "(x)", &n);
      g_snprintf (nbuf, sizeof nbuf, "%" G_GINT64_FORMAT, n);
      args[0] = nbuf;
      cmacs_dbus_eval_to_reply (iv,
        "(save-excursion (goto-line %s)"
        " (buffer-substring-no-properties (line-beginning-position)"
        "                                  (line-end-position)))",
        args, 1);
    }
  else if (g_strcmp0 (m, "Append") == 0)
    {
      const gchar *text; const gchar *args[1];
      g_variant_get (p, "(&s)", &text); args[0] = text;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (goto-char (point-max)) (insert \"%s\") \"ok\")", args, 1);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_text_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_text_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
