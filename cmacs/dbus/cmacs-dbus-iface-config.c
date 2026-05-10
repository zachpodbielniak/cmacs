/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-config.c --- variable / theme / font / mode.
 * Mirrors cmacsgi set/get/theme/font/mode. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Config'>"
  "  <method name='Set'><arg type='s' name='var' direction='in'/>"
  "    <arg type='s' name='value' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Get'><arg type='s' name='var' direction='in'/>"
  "    <arg type='s' name='value' direction='out'/></method>"
  "  <method name='Theme'><arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Font'><arg type='s' name='family' direction='in'/>"
  "    <arg type='i' name='size' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Mode'><arg type='s' name='mode' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Set") == 0)
    {
      const gchar *var, *val; const gchar *args[2];
      g_variant_get (p, "(&s&s)", &var, &val);
      args[0] = var; args[1] = val;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (set (intern \"%s\") (read \"%s\")) \"ok\")", args, 2);
    }
  else if (g_strcmp0 (m, "Get") == 0)
    {
      const gchar *var; const gchar *args[1];
      g_variant_get (p, "(&s)", &var); args[0] = var;
      cmacs_dbus_eval_to_reply (iv,
        "(format \"%%S\" (symbol-value (intern \"%s\")))", args, 1);
    }
  else if (g_strcmp0 (m, "Theme") == 0)
    {
      const gchar *name; const gchar *args[1];
      g_variant_get (p, "(&s)", &name); args[0] = name;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (mapc #'disable-theme custom-enabled-themes)"
        " (load-theme (intern \"%s\") t) \"ok\")", args, 1);
    }
  else if (g_strcmp0 (m, "Font") == 0)
    {
      const gchar *fam; gint32 size;
      gchar sbuf[16]; const gchar *args[2];
      g_variant_get (p, "(&si)", &fam, &size);
      g_snprintf (sbuf, sizeof sbuf, "%d", size > 0 ? size : 11);
      args[0] = fam; args[1] = sbuf;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (set-frame-font (format \"%s-%s\")) \"ok\")", args, 2);
    }
  else if (g_strcmp0 (m, "Mode") == 0)
    {
      const gchar *mode; const gchar *args[1];
      g_variant_get (p, "(&s)", &mode); args[0] = mode;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (let ((m (intern \"%s\")))"
        "  (if (string-suffix-p \"-mode\" (symbol-name m))"
        "    (funcall m)"
        "    (funcall (intern (concat (symbol-name m) \"-mode\")))))"
        " \"ok\")", args, 1);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_config_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_config_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
