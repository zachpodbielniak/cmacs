/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-calculator.c --- cmacs-calculator surface via D-Bus.
 *
 * org.cmacs.Editor1.Calc
 *
 * MCP parity: mirrors calc_eval / calc_eval_symbolic / calc_convert_units
 * / calc_list / calc_describe in cmacs/mcp/cmacs-mcp-tools-calculator.c
 * (sync discipline: adding a tool there requires a matching method here,
 * and vice versa).  The elisp bodies are identical to the MCP handlers'.
 *
 * Every handler routes through the Elisp dispatch path, so a D-Bus caller
 * runs the same engine -- same corrected precedence, radian angle mode and
 * strict validation -- as M-x, the sheet buffer and the MCP tools. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_CALCULATOR)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Calc'>"
  "    <method name='Eval'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='EvalSymbolic'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ConvertUnits'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='units' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListCalculators'>"
  "      <arg type='s' name='category' direction='in'/>"
  "      <arg type='s' name='calculators' direction='out'/>"
  "    </method>"
  "    <method name='Describe'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='description' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  /* Every method of this interface has a row in
     cmacs-dbus-forward-table.h and is served from the capability
     table: there is no per-method code here.  The fallback below is
     for a method added to the XML above without a row or a body.  */
  if (cmacs_dbus_forward (i, m, p, iv))
    return;

  g_dbus_method_invocation_return_dbus_error (
    iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_calculator_register (GDBusConnection *conn,
                                      const gchar *path, GError **error)
{
  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_calculator_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_CALCULATOR */
