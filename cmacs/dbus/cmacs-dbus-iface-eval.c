/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-eval.c --- core eval + GI methods on org.cmacs.Editor1.
 *
 * Six methods that cmacsgi's transport (cmacs-api-transport.c:451-506)
 * uses unchanged from before the multi-interface refactor:
 *
 *   Eval (s) -> (s)
 *   FindFile (s)
 *   Message (s)
 *   GiRequire (ss) -> (b)
 *   GiCall (ssas) -> (s)
 *   GiListFunctions (s) -> (as)
 *
 * The Gowl* methods that previously lived here have moved to typed
 * sibling interfaces:
 *   org.cmacs.Editor1.Compositor   (clients, keybinds, rules, lock, ...)
 *   org.cmacs.Editor1.Monitor      (display configuration)
 *
 * cmacsgi never called the Gowl methods directly (it routed via
 * elisp eval), so this is a clean rename rather than a wire break. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1'>"
  "    <method name='Eval'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='FindFile'>"
  "      <arg type='s' name='path' direction='in'/>"
  "    </method>"
  "    <method name='Message'>"
  "      <arg type='s' name='text' direction='in'/>"
  "    </method>"
  "    <method name='GiRequire'>"
  "      <arg type='s' name='namespace_' direction='in'/>"
  "      <arg type='s' name='version' direction='in'/>"
  "      <arg type='b' name='success' direction='out'/>"
  "    </method>"
  "    <method name='GiCall'>"
  "      <arg type='s' name='namespace_' direction='in'/>"
  "      <arg type='s' name='function' direction='in'/>"
  "      <arg type='as' name='args' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GiListFunctions'>"
  "      <arg type='s' name='namespace_' direction='in'/>"
  "      <arg type='as' name='functions' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method_call (GDBusConnection       *connection,
                const gchar           *sender,
                const gchar           *object_path,
                const gchar           *interface_name,
                const gchar           *method_name,
                GVariant              *parameters,
                GDBusMethodInvocation *invocation,
                gpointer               user_data)
{
  (void) connection; (void) sender; (void) object_path;
  (void) interface_name; (void) user_data;

  if (g_strcmp0 (method_name, "Eval") == 0)
    {
      const gchar *expr;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s)", &expr);
      result = cmacs_dispatch_eval (expr, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "FindFile") == 0)
    {
      const gchar *path;
      g_variant_get (parameters, "(&s)", &path);
      cmacs_dispatch_find_file (path);
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else if (g_strcmp0 (method_name, "Message") == 0)
    {
      const gchar *text;
      g_variant_get (parameters, "(&s)", &text);
      cmacs_dispatch_message (text);
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else if (g_strcmp0 (method_name, "GiRequire") == 0)
    {
      const gchar *ns, *ver;
      GError *err = NULL;
      gboolean ok;

      g_variant_get (parameters, "(&s&s)", &ns, &ver);
      ok = cmacs_dispatch_gi_require (ns, ver, &err);
      if (err != NULL)
        cmacs_dbus_return_gerror (invocation, err);
      else
        g_dbus_method_invocation_return_value (
          invocation, g_variant_new ("(b)", ok));
    }
  else if (g_strcmp0 (method_name, "GiCall") == 0)
    {
      const gchar *ns, *func, *arg;
      GVariantIter *iter;
      GPtrArray *args_arr;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s&sas)", &ns, &func, &iter);

      args_arr = g_ptr_array_new ();
      while (g_variant_iter_next (iter, "&s", &arg))
        g_ptr_array_add (args_arr, (gpointer) arg);
      g_variant_iter_free (iter);

      result = cmacs_dispatch_gi_call (
        ns, func, (const gchar *const *) args_arr->pdata,
        (gint) args_arr->len, &err);
      g_ptr_array_free (args_arr, TRUE);

      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GiListFunctions") == 0)
    {
      const gchar *ns;
      gchar **funcs;
      GVariantBuilder builder;
      gint i;

      g_variant_get (parameters, "(&s)", &ns);
      funcs = cmacs_dispatch_gi_list_functions (ns);

      g_variant_builder_init (&builder, G_VARIANT_TYPE ("as"));
      for (i = 0; funcs[i] != NULL; i++)
        g_variant_builder_add (&builder, "s", funcs[i]);
      g_strfreev (funcs);

      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(as)", &builder));
    }
}


static const GDBusInterfaceVTable iface_vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_eval_register (GDBusConnection *conn,
                                 const gchar     *path,
                                 GError         **error)
{
  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL)
        return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0],
    &iface_vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_eval_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0)
    g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    {
      g_dbus_node_info_unref (iface_info);
      iface_info = NULL;
    }
}

#endif /* HAVE_CMACS_GLIB */
