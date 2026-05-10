/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-cintrospect.c --- C runtime introspection.
 * Mirrors cmacsgi `c list/symbol/type/source/addr/defuns/stack`. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Cintrospect'>"
  "  <method name='List'>"
  "    <arg type='s' name='kind' direction='in'/>"
  "    <arg type='s' name='glob' direction='in'/>"
  "    <arg type='i' name='limit' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SymbolInfo'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='plist' direction='out'/></method>"
  "  <method name='TypeInfo'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='plist' direction='out'/></method>"
  "  <method name='FunctionSource'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='cons' direction='out'/></method>"
  "  <method name='AddrToSource'>"
  "    <arg type='t' name='addr' direction='in'/>"
  "    <arg type='s' name='triple' direction='out'/></method>"
  "  <method name='ListDefuns'>"
  "    <arg type='s' name='glob' direction='in'/>"
  "    <arg type='i' name='limit' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='DefunInfo'>"
  "    <arg type='s' name='sym' direction='in'/>"
  "    <arg type='s' name='plist' direction='out'/></method>"
  "  <method name='StackTrace'>"
  "    <arg type='i' name='depth' direction='in'/>"
  "    <arg type='s' name='frames' direction='out'/></method>"
  "  <method name='ListObjects'>"
  "    <arg type='s' name='objects' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

/* Wrap with fboundp guard so absence of cintrospect (build flag off)
   yields a friendly message rather than a hard error. */
#define GUARD(probe, body) \
  "(if (fboundp '" probe ") " body \
  " \"cintrospect not enabled in this build\")"

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    {
      const gchar *kind, *glob;
      gint32 limit;
      const gchar *args[3];
      gchar lbuf[16];
      g_variant_get (p, "(&s&si)", &kind, &glob, &limit);
      g_snprintf (lbuf, sizeof lbuf, "%d", limit > 0 ? limit : 0);
      args[0] = kind;
      args[1] = glob;
      args[2] = lbuf;
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-list",
         "(format \"%%S\" (cmacs-c-list '%s %s%s%s %s))"),
        (const gchar *[]) {
          kind,
          glob && *glob ? "\"" : "",
          glob && *glob ? glob : "nil",
          glob && *glob ? "\"" : "",
          (limit > 0) ? lbuf : "nil"
        }, 5);
    }
  else if (g_strcmp0 (m, "SymbolInfo") == 0)
    {
      const gchar *name;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &name);
      args[0] = name;
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-symbol-info",
         "(format \"%%S\" (cmacs-c-symbol-info \"%s\"))"),
        args, 1);
    }
  else if (g_strcmp0 (m, "TypeInfo") == 0)
    {
      const gchar *name;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &name);
      args[0] = name;
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-type-info",
         "(format \"%%S\" (cmacs-c-type-info \"%s\"))"),
        args, 1);
    }
  else if (g_strcmp0 (m, "FunctionSource") == 0)
    {
      const gchar *name;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &name);
      args[0] = name;
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-function-source",
         "(format \"%%S\" (cmacs-c-function-source \"%s\"))"),
        args, 1);
    }
  else if (g_strcmp0 (m, "AddrToSource") == 0)
    {
      guint64 addr;
      gchar abuf[32];
      const gchar *args[1];
      g_variant_get (p, "(t)", &addr);
      g_snprintf (abuf, sizeof abuf, "%" G_GUINT64_FORMAT, addr);
      args[0] = abuf;
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-addr-to-source",
         "(format \"%%S\" (cmacs-c-addr-to-source %s))"),
        args, 1);
    }
  else if (g_strcmp0 (m, "ListDefuns") == 0)
    {
      const gchar *glob;
      gint32 limit;
      gchar lbuf[16];
      g_variant_get (p, "(&si)", &glob, &limit);
      g_snprintf (lbuf, sizeof lbuf, "%d", limit > 0 ? limit : 0);
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-list-defuns",
         "(format \"%%S\" (cmacs-c-list-defuns %s%s%s %s))"),
        (const gchar *[]) {
          glob && *glob ? "\"" : "",
          glob && *glob ? glob : "nil",
          glob && *glob ? "\"" : "",
          (limit > 0) ? lbuf : "nil"
        }, 4);
    }
  else if (g_strcmp0 (m, "DefunInfo") == 0)
    {
      const gchar *sym;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &sym);
      args[0] = sym;
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-defun-info",
         "(format \"%%S\" (cmacs-c-defun-info \"%s\"))"),
        args, 1);
    }
  else if (g_strcmp0 (m, "StackTrace") == 0)
    {
      gint32 depth;
      gchar dbuf[16];
      const gchar *args[1];
      g_variant_get (p, "(i)", &depth);
      g_snprintf (dbuf, sizeof dbuf, "%d", depth > 0 ? depth : 0);
      args[0] = (depth > 0) ? dbuf : "nil";
      cmacs_dbus_eval_to_reply (iv,
        GUARD ("cmacs-c-stack-trace",
         "(format \"%%S\" (cmacs-c-stack-trace %s))"),
        args, 1);
    }
  else if (g_strcmp0 (m, "ListObjects") == 0)
    cmacs_dbus_eval_to_reply (iv,
      GUARD ("cmacs-c-list-objects",
       "(format \"%S\" (cmacs-c-list-objects))"),
      NULL, 0);
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_cintrospect_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_cintrospect_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
