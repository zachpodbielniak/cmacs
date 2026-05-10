/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-watch.c --- observable Lisp form watchers (Phase 5)
 *
 * Adds org.cmacs.Editor1.Watch at /org/cmacs/Editor with two methods:
 *
 *   Add (s expr) -> o handle
 *      Register a watch on EXPR.  Returns object path
 *      /org/cmacs/Editor/Watch/<token>.  After every command, EXPR is
 *      evaluated; if its printed form has changed since the previous
 *      poll, a `Changed' signal fires on the watch object's iface.
 *
 *   Remove (o handle) -> b
 *      Stop watching, unregister the per-watch path.
 *
 * Per-watch object exposes:
 *   org.cmacs.Editor1.WatchHandle:
 *     property Expr (s, read-only)
 *     property LastValue (s, read-only)
 *     signal Changed (s new_value)
 *
 * The actual evaluation + change detection lives in
 * lisp/cmacs/cmacs-dbus-watch.el; this C side just owns the iface
 * registration and signal emission. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"
#include <gio/gio.h>
#include <string.h>

#define WATCH_PATH_PREFIX "/org/cmacs/Editor/Watch/"

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Watch'>"
  "  <method name='Add'>"
  "    <arg type='s' name='expr' direction='in'/>"
  "    <arg type='o' name='handle' direction='out'/></method>"
  "  <method name='Remove'>"
  "    <arg type='o' name='handle' direction='in'/>"
  "    <arg type='b' name='ok' direction='out'/></method>"
  "  <method name='List'>"
  "    <arg type='ao' name='handles' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;
static guint next_watch_id = 1;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Add") == 0)
    {
      const gchar *expr;
      gchar *path, *escaped, *register_call;
      gchar *r;
      guint id;

      g_variant_get (p, "(&s)", &expr);
      id = next_watch_id++;
      path = g_strdup_printf (WATCH_PATH_PREFIX "%u", id);

      /* Delegate the actual watch-state tracking to the Lisp helper. */
      escaped = cmacs_dbus_lisp_escape (expr);
      register_call = g_strdup_printf (
        "(when (fboundp 'cmacs-dbus-watch--register)"
        " (cmacs-dbus-watch--register \"%s\" %u \"%s\")"
        " t)", path, id, escaped);
      r = cmacs_dispatch_eval (register_call, &err);
      g_free (register_call); g_free (escaped);
      if (r == NULL) { g_free (path); cmacs_dbus_return_gerror (iv, err); return; }
      g_free (r);

      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(o)", path));
      g_free (path);
    }
  else if (g_strcmp0 (m, "Remove") == 0)
    {
      const gchar *handle;
      gchar *call, *r;
      g_variant_get (p, "(&o)", &handle);
      call = g_strdup_printf (
        "(if (fboundp 'cmacs-dbus-watch--unregister)"
        " (cmacs-dbus-watch--unregister \"%s\") nil)", handle);
      r = cmacs_dispatch_eval (call, &err);
      g_free (call);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(b)", g_strcmp0 (r, "t") == 0));
      g_free (r);
    }
  else if (g_strcmp0 (m, "List") == 0)
    {
      gchar *r = cmacs_dispatch_eval (
        "(if (boundp 'cmacs-dbus-watch--paths)"
        " (mapconcat #'identity cmacs-dbus-watch--paths \"|||\")"
        " \"\")", &err);
      GVariantBuilder b;
      gchar **paths;
      gsize j;

      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }

      {
        size_t len = strlen (r);
        if (len >= 2 && r[0] == '"' && r[len - 1] == '"')
          { memmove (r, r + 1, len - 2); r[len - 2] = '\0'; }
      }
      paths = g_strsplit (r, "|||", -1);
      g_free (r);
      g_variant_builder_init (&b, G_VARIANT_TYPE ("ao"));
      for (j = 0; paths[j] != NULL; j++)
        if (paths[j][0] != '\0' && paths[j][0] == '/')
          g_variant_builder_add (&b, "o", paths[j]);
      g_strfreev (paths);
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(ao)", &b));
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_watch_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_watch_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#include <string.h>
#endif
