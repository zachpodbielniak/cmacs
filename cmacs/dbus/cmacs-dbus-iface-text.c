/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-text.c --- text editing.
 * Mirrors cmacsgi insert/delete/line/append.  Every method takes a
 * trailing BUFFER argument; the empty string means "the current
 * buffer" (the original point-relative behavior). */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Text'>"
  "  <method name='Insert'><arg type='s' name='text' direction='in'/>"
  "    <arg type='s' name='buffer' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Delete'><arg type='x' name='start' direction='in'/>"
  "    <arg type='x' name='end' direction='in'/>"
  "    <arg type='s' name='buffer' direction='in'/>"
  "    <arg type='s' name='deleted' direction='out'/></method>"
  "  <method name='Line'><arg type='x' name='n' direction='in'/>"
  "    <arg type='s' name='buffer' direction='in'/>"
  "    <arg type='s' name='content' direction='out'/></method>"
  "  <method name='Append'><arg type='s' name='text' direction='in'/>"
  "    <arg type='s' name='buffer' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

/* Elisp prelude selecting BUFFER ("" -> current buffer).  The two %s
 * placeholders both receive the buffer name. */
#define TEXT_IN_BUFFER                                                  \
  "(with-current-buffer (if (string= \"%s\" \"\")"                     \
  "                         (current-buffer) \"%s\")"

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  /* Served from the capability table when the method has a row in
     cmacs-dbus-forward-table.h; the bodies below are the methods
     that have none.  */
  if (cmacs_dbus_forward (i, m, p, iv))
    return;

  if (g_strcmp0 (m, "Insert") == 0)
    {
      const gchar *text, *buffer;
      const gchar *args[3];
      g_variant_get (p, "(&s&s)", &text, &buffer);
      args[0] = buffer; args[1] = buffer; args[2] = text;
      cmacs_dbus_eval_to_reply_string (iv,
        TEXT_IN_BUFFER " (insert \"%s\") \"ok\")", args, 3);
    }
  else if (g_strcmp0 (m, "Append") == 0)
    {
      const gchar *text, *buffer;
      const gchar *args[3];
      g_variant_get (p, "(&s&s)", &text, &buffer);
      args[0] = buffer; args[1] = buffer; args[2] = text;
      cmacs_dbus_eval_to_reply_string (iv,
        TEXT_IN_BUFFER
        " (save-excursion (goto-char (point-max)) (insert \"%s\"))"
        " \"ok\")",
        args, 3);
    }
  else
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
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
