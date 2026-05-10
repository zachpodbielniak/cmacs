/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-file.c --- file open/save/close/recent.
 * Mirrors cmacsgi open/save/close/recent. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.File'>"
  "  <method name='Open'><arg type='s' name='path' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Save'><arg type='s' name='path' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Close'><arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Recent'><arg type='i' name='n' direction='in'/>"
  "    <arg type='s' name='paths' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Open") == 0)
    {
      const gchar *path; const gchar *args[1];
      g_variant_get (p, "(&s)", &path); args[0] = path;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (find-file \"%s\") \"ok\")", args, 1);
    }
  else if (g_strcmp0 (m, "Save") == 0)
    {
      const gchar *path; const gchar *args[1];
      g_variant_get (p, "(&s)", &path); args[0] = path;
      if (path && *path)
        cmacs_dbus_eval_to_reply (iv,
          "(progn (with-current-buffer (find-buffer-visiting \"%s\")"
          "        (save-buffer)) \"ok\")", args, 1);
      else
        cmacs_dbus_eval_to_reply (iv,
          "(progn (save-buffer) \"ok\")", NULL, 0);
    }
  else if (g_strcmp0 (m, "Close") == 0)
    {
      const gchar *name; const gchar *args[1];
      g_variant_get (p, "(&s)", &name); args[0] = name;
      if (name && *name)
        cmacs_dbus_eval_to_reply (iv,
          "(progn (kill-buffer \"%s\") \"ok\")", args, 1);
      else
        cmacs_dbus_eval_to_reply (iv,
          "(progn (kill-buffer (current-buffer)) \"ok\")", NULL, 0);
    }
  else if (g_strcmp0 (m, "Recent") == 0)
    {
      gint32 n; gchar nbuf[16]; const gchar *args[1];
      g_variant_get (p, "(i)", &n);
      g_snprintf (nbuf, sizeof nbuf, "%d", n > 0 ? n : 20);
      args[0] = nbuf;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (require 'recentf)"
        " (mapconcat #'identity (seq-take recentf-list %s) \"|||\"))",
        args, 1);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_file_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_file_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
