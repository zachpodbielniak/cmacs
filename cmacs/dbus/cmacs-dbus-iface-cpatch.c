/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-cpatch.c --- runtime C hot-patching via D-Bus.
 * Mirrors cmacsgi `c patch/unpatch/patches/unpatch-all`.
 *
 * Probes fboundp on each target DEFUN -- the cpatch DEFUNs only
 * exist when configure had --enable-cmacs-cpatch.  Without that,
 * methods return a friendly message rather than fail. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Cpatch'>"
  "  <method name='PatchDefun'>"
  "    <arg type='s' name='sym' direction='in'/>"
  "    <arg type='s' name='fn_name' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='UnpatchDefun'>"
  "    <arg type='s' name='sym' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='PatchList'>"
  "    <arg type='s' name='patches' direction='out'/></method>"
  "  <method name='UnpatchAll'>"
  "    <arg type='s' name='count' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

#define CPATCH_GUARD(probe, body) \
  "(if (fboundp '" probe ") " body \
  " \"cpatch not enabled in this build (configure --enable-cmacs-cpatch)\")"

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "PatchDefun") == 0)
    {
      const gchar *sym, *fn;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &sym, &fn);
      args[0] = fn;  args[1] = sym;
      cmacs_dbus_eval_to_reply (iv,
        CPATCH_GUARD ("cmacs-c-patch-defun",
         "(let* ((info (cmacs-c-symbol-info \"%s\"))"
         "       (addr (and info (plist-get info :addr))))"
         "  (if addr"
         "    (format \"%%S\" (cmacs-c-patch-defun (intern \"%s\") addr))"
         "    \"function not found\"))"),
        args, 2);
    }
  else if (g_strcmp0 (m, "UnpatchDefun") == 0)
    {
      const gchar *sym;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &sym);
      args[0] = sym;
      cmacs_dbus_eval_to_reply (iv,
        CPATCH_GUARD ("cmacs-c-unpatch-defun",
         "(format \"%%S\" (cmacs-c-unpatch-defun (intern \"%s\")))"),
        args, 1);
    }
  else if (g_strcmp0 (m, "PatchList") == 0)
    cmacs_dbus_eval_to_reply (iv,
      CPATCH_GUARD ("cmacs-c-patch-list",
       "(format \"%S\" (cmacs-c-patch-list))"),
      NULL, 0);
  else if (g_strcmp0 (m, "UnpatchAll") == 0)
    cmacs_dbus_eval_to_reply (iv,
      CPATCH_GUARD ("cmacs-c-unpatch-all",
       "(format \"%d\" (cmacs-c-unpatch-all))"),
      NULL, 0);
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_cpatch_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_cpatch_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
