/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-brigade.c --- subagent control via D-Bus.
 *
 * org.cmacs.Editor1.Brigade
 *
 * MCP parity: mirrors agent_spawn / agent_status / agent_result /
 * agent_cancel / agent_list, published from the brigade tool registry by
 * cmacs/mcp/cmacs-mcp-tools-brigade.c (sync discipline: a control added
 * on one surface wants a matching method here, and vice versa).
 *
 * The point of having it here as well is that D-Bus reaches a running
 * cmacs from outside it -- a shell script, a systemd unit, another
 * machine over the emacsctl ssh tunnel -- without going through an MCP
 * client or an agent at all.  Every handler routes through the Elisp
 * dispatch path, so a D-Bus caller drives the same queue, concurrency
 * cap and state machine as the dashboard.  */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_AI_BRIGADE)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Brigade'>"
  "    <method name='Spawn'>"
  "      <arg type='s' name='task' direction='in'/>"
  "      <arg type='s' name='agent' direction='in'/>"
  "      <arg type='s' name='title' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='id' direction='out'/>"
  "    </method>"
  "    <method name='Status'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='Result'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='output' direction='out'/>"
  "    </method>"
  "    <method name='Cancel'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='List'>"
  "      <arg type='s' name='tasks' direction='out'/>"
  "    </method>"
  "    <method name='Agents'>"
  "      <arg type='s' name='agents' direction='out'/>"
  "    </method>"
  "    <method name='Providers'>"
  "      <arg type='s' name='providers' direction='out'/>"
  "    </method>"
  "    <method name='Models'>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='models' direction='out'/>"
  "    </method>"
  /* The mailbox: continuing a conversation with a task rather than
   * starting a new one, and reading what any task has been doing. */
  "    <method name='Send'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='message' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Inbox'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='messages' direction='out'/>"
  "    </method>"
  "    <method name='Drop'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='index' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Log'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='from_turn' direction='in'/>"
  "      <arg type='s' name='kinds' direction='in'/>"
  "      <arg type='s' name='log' direction='out'/>"
  "    </method>"
  "    <method name='Close'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Evaluate EXPR and reply with the raw string result.  Consumes EXPR. */
static void
eval_to_reply (GDBusMethodInvocation *iv, gchar *expr)
{
  gchar *result;
  GError *err = NULL;

  result = cmacs_dispatch_eval_string (expr, &err);
  g_free (expr);
  if (result == NULL)
    {
      cmacs_dbus_return_gerror (iv, err);
      return;
    }
  g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", result));
  g_free (result);
}

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

  if (g_strcmp0 (m, "Agents") == 0)
    {
      eval_to_reply (iv, g_strdup (
        "(progn (require 'cmacs-brigade)"
        " (mapconcat (lambda (a) (format \"%s\" a))"
        "  (cmacs-brigade-registry-list 'agent) \"\\n\"))"));
    }
  else
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_brigade_register (GDBusConnection *conn,
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
cmacs_dbus_iface_brigade_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_AI_BRIGADE */
