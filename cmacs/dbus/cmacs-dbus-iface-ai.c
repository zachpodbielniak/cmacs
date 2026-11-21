/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-ai.c --- cmacs-ai coding agent surface via D-Bus.
 *
 * org.cmacs.Editor1.Ai
 *
 * MCP parity: mirrors ai_prompt / ai_list_providers / ai_list_models
 * / ai_open_chat in cmacs/mcp/cmacs-mcp-tools-ai.c (sync discipline:
 * adding a tool there requires a matching method here, and vice
 * versa).  The elisp bodies are identical to the MCP handlers'. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_AI)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Ai'>"
  "    <method name='ListProviders'>"
  "      <arg type='s' name='providers' direction='out'/>"
  "    </method>"
  "    <method name='ListModels'>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='models' direction='out'/>"
  "    </method>"
  "    <method name='Prompt'>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='system' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='response' direction='out'/>"
  "    </method>"
  "    <method name='Call'>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='system' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='b' name='tools' direction='in'/>"
  "      <arg type='s' name='response' direction='out'/>"
  "    </method>"
  "    <method name='GenerateImage'>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='aspect' direction='in'/>"
  "      <arg type='s' name='references' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='OpenChat'>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='buffer' direction='out'/>"
  "    </method>"
  "    <method name='Research'>"
  "      <arg type='s' name='question' direction='in'/>"
  "      <arg type='b' name='deep' direction='in'/>"
  "      <arg type='i' name='pages' direction='in'/>"
  "      <arg type='s' name='answer' direction='out'/>"
  "    </method>"
  "    <method name='WebFetch'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='archive' direction='in'/>"
  "      <arg type='i' name='max_chars' direction='in'/>"
  "      <arg type='s' name='text' direction='out'/>"
  "    </method>"
  "    <method name='Lql'>"
  "      <arg type='s' name='query' direction='in'/>"
  "      <arg type='b' name='explain' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
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
cmacs_dbus_iface_ai_register (GDBusConnection *conn, const gchar *path,
                              GError **error)
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
cmacs_dbus_iface_ai_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_AI */
