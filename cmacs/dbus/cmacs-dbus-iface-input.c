/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-input.c --- keyboard input and interactive
 * commands via D-Bus.
 *
 * org.cmacs.Editor1.Input
 *
 * MCP parity: mirrors send_keys / execute_command in
 * cmacs/mcp/cmacs-mcp-tools-input.c (sync discipline: adding a tool
 * there requires a matching method here, and vice versa). */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Input'>"
  "    <method name='SendKeys'>"
  "      <arg type='s' name='keys' direction='in'/>"
  "      <arg type='b' name='ok' direction='out'/>"
  "    </method>"
  "    <method name='ExecuteCommand'>"
  "      <arg type='s' name='command' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* A command name must be a plain elisp symbol --- reject anything
 * that could splice extra forms into the generated expression. */
static gboolean
valid_symbol_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  for (; *s != '\0'; s++)
    if (!g_ascii_isalnum (*s) && strchr ("-_+*/<>=!?:", *s) == NULL)
      return FALSE;
  return TRUE;
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "SendKeys") == 0)
    {
      const gchar *keys;
      const gchar *args[1];
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s)", &keys);
      args[0] = keys;
      expr = cmacs_dbus_build_elisp (
        "(progn (execute-kbd-macro (kbd \"%s\")) t)", args, 1);
      result = cmacs_dispatch_eval (expr, &err);
      g_free (expr);
      if (result == NULL)
        {
          cmacs_dbus_return_gerror (iv, err);
          return;
        }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(b)", TRUE));
      g_free (result);
    }
  else if (g_strcmp0 (m, "ExecuteCommand") == 0)
    {
      const gchar *command;
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s)", &command);
      if (!valid_symbol_name (command))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error",
            "command must be a plain elisp symbol name");
          return;
        }
      expr = g_strdup_printf ("(call-interactively '%s)", command);
      result = cmacs_dispatch_eval (expr, &err);
      g_free (expr);
      if (result == NULL)
        {
          cmacs_dbus_return_gerror (iv, err);
          return;
        }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(s)", result));
      g_free (result);
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_input_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_input_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
