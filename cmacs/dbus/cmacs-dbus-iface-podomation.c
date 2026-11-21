/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-podomation.c --- podomation automation engine via
 * D-Bus.
 *
 * org.cmacs.Editor1.Podomation
 *
 * MCP parity: mirrors the podomation_* tools in
 * cmacs/mcp/cmacs-mcp-tools-shell.c (sync discipline: adding a tool
 * there requires a matching method here, and vice versa).  The elisp
 * bodies are identical to the MCP handlers'; event/context payloads
 * arrive as a{ss} dicts instead of JSON objects. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_PODOMATION)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Podomation'>"
  "    <method name='Control'>"
  "      <arg type='s' name='action' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='EmitEvent'>"
  "      <arg type='s' name='event' direction='in'/>"
  "      <arg type='a{ss}' name='data' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='RunPod'>"
  "      <arg type='s' name='pod' direction='in'/>"
  "      <arg type='s' name='event' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='EvalDsl'>"
  "      <arg type='s' name='dsl' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ReplEval'>"
  "      <arg type='s' name='line' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListPods'>"
  "      <arg type='s' name='pods' direction='out'/>"
  "    </method>"
  "    <method name='ListModules'>"
  "      <arg type='s' name='modules' direction='out'/>"
  "    </method>"
  "    <method name='LoadFile'>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Reload'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='SetContext'>"
  "      <arg type='a{ss}' name='context' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Stats'>"
  "      <arg type='s' name='stats' direction='out'/>"
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

  /* Served from the capability table when the method has a row in
     cmacs-dbus-forward-table.h; the bodies below are the methods
     that have none.  */
  if (cmacs_dbus_forward (i, m, p, iv))
    return;

  if (g_strcmp0 (m, "EvalDsl") == 0)
    {
      const gchar *dsl;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &dsl);
      args[0] = dsl;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (cmacs-podomation-eval-dsl \"%s\") \"DSL evaluated\")",
        args, 1);
    }
  else if (g_strcmp0 (m, "ReplEval") == 0)
    {
      const gchar *line;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &line);
      args[0] = line;
      cmacs_dbus_eval_to_reply_string (iv,
        "(let ((r (cmacs-podomation-repl-eval \"%s\")))"
        "  (format \"%%s: %%s\" (car r) (or (cdr r) \"\")))",
        args, 1);
    }
  else
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_podomation_register (GDBusConnection *conn,
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
cmacs_dbus_iface_podomation_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_PODOMATION */
