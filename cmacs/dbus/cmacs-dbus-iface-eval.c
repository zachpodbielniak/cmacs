/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-eval.c --- back-compat org.cmacs.Editor1 methods.
 *
 * Hosts the methods that the cmacs D-Bus surface exposed before the
 * multi-interface refactor.  Bit-for-bit compatible with cmacsgi's
 * existing transport (cmacs/api/cmacs-api-transport.c:451-506) and
 * with any external tool that calls org.cmacs.Editor1.* directly.
 *
 *   Eval (s) -> (s)
 *   FindFile (s)
 *   Message (s)
 *   GiRequire (ss) -> (b)
 *   GiCall (ssas) -> (s)
 *   GiListFunctions (s) -> (as)
 *
 *   GowlListClients / GowlFocusedClient / GowlSpawn / GowlListMonitors
 *   GowlAddKeybind / GowlListKeybinds / GowlAddRule / GowlSetMfact
 *   GowlSetNmaster / GowlViewTags / GowlLock / GowlUnlock
 *   GowlReloadConfig / GowlConfigGet / GowlFindClient
 *   GowlMonitorInfo / GowlMonitorModes / GowlSetMonitorMode
 *   GowlMonitorPosition / GowlSetMonitorPosition / GowlSetMonitorEnabled
 *   GowlSetMonitorScale / GowlSetMonitorTransform
 *
 * Phase 3 will extract the Gowl methods into typed
 * org.cmacs.Editor1.Monitor / .Bar / .Compositor interfaces;
 * Phase 1 keeps everything on org.cmacs.Editor1 so the wire surface
 * is unchanged.
 */

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
#ifdef HAVE_CMACS_GOWL
  "    <method name='GowlListClients'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlFocusedClient'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSpawn'>"
  "      <arg type='s' name='command' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlListMonitors'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlAddKeybind'>"
  "      <arg type='s' name='key' direction='in'/>"
  "      <arg type='i' name='action' direction='in'/>"
  "      <arg type='s' name='arg' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlListKeybinds'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlAddRule'>"
  "      <arg type='s' name='app_id' direction='in'/>"
  "      <arg type='s' name='title' direction='in'/>"
  "      <arg type='u' name='tags' direction='in'/>"
  "      <arg type='b' name='floating' direction='in'/>"
  "      <arg type='i' name='monitor' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSetMfact'>"
  "      <arg type='d' name='mfact' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSetNmaster'>"
  "      <arg type='i' name='n' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlViewTags'>"
  "      <arg type='u' name='tagmask' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlLock'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlUnlock'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlReloadConfig'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlConfigGet'>"
  "      <arg type='s' name='property' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlFindClient'>"
  "      <arg type='s' name='pattern' direction='in'/>"
  "      <arg type='s' name='by' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlMonitorInfo'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlMonitorModes'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSetMonitorMode'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='i' name='width' direction='in'/>"
  "      <arg type='i' name='height' direction='in'/>"
  "      <arg type='i' name='refresh_mhz' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlMonitorPosition'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSetMonitorPosition'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='i' name='x' direction='in'/>"
  "      <arg type='i' name='y' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSetMonitorEnabled'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='enabled' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSetMonitorScale'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='d' name='scale' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GowlSetMonitorTransform'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='i' name='transform' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
#endif /* HAVE_CMACS_GOWL */
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

#ifdef HAVE_CMACS_GOWL

  /* ── Gowl compositor methods (bypass elisp for performance) ──────── */

  else if (g_strcmp0 (method_name, "GowlListClients") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_list_clients (&err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlFocusedClient") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_focused_client (&err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSpawn") == 0)
    {
      const gchar *command;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s)", &command);
      result = cmacs_dispatch_gowl_spawn (command, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlListMonitors") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_list_monitors (&err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlAddKeybind") == 0)
    {
      const gchar *key, *arg;
      gint action;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&si&s)", &key, &action, &arg);
      result = cmacs_dispatch_gowl_add_keybind (key, action, arg, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlListKeybinds") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_list_keybinds (&err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlAddRule") == 0)
    {
      const gchar *app_id, *title;
      guint32 tags;
      gboolean floating;
      gint monitor;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s&subi)", &app_id, &title, &tags,
                     &floating, &monitor);
      result = cmacs_dispatch_gowl_add_rule (app_id, title, tags, floating,
                                              monitor, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSetMfact") == 0)
    {
      gdouble mfact;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(d)", &mfact);
      result = cmacs_dispatch_gowl_set_mfact (mfact, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSetNmaster") == 0)
    {
      gint n;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(i)", &n);
      result = cmacs_dispatch_gowl_set_nmaster (n, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlViewTags") == 0)
    {
      guint32 tagmask;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(u)", &tagmask);
      result = cmacs_dispatch_gowl_view_tags (tagmask, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlLock") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_lock (&err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlUnlock") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_unlock (&err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlReloadConfig") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_reload_config (&err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlConfigGet") == 0)
    {
      const gchar *property;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s)", &property);
      result = cmacs_dispatch_gowl_config_get (property, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlFindClient") == 0)
    {
      const gchar *pattern, *by;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s&s)", &pattern, &by);
      result = cmacs_dispatch_gowl_find_client (pattern, by, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlMonitorInfo") == 0)
    {
      const gchar *name;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s)", &name);
      result = cmacs_dispatch_gowl_monitor_info (name, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlMonitorModes") == 0)
    {
      const gchar *name;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s)", &name);
      result = cmacs_dispatch_gowl_monitor_modes (name, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSetMonitorMode") == 0)
    {
      const gchar *name;
      gint w, h, refresh;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&siii)", &name, &w, &h, &refresh);
      result = cmacs_dispatch_gowl_set_monitor_mode (name, w, h, refresh,
                                                       &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlMonitorPosition") == 0)
    {
      const gchar *name;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s)", &name);
      result = cmacs_dispatch_gowl_monitor_position (name, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSetMonitorPosition") == 0)
    {
      const gchar *name;
      gint x, y;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&sii)", &name, &x, &y);
      result = cmacs_dispatch_gowl_set_monitor_pos (name, x, y, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSetMonitorEnabled") == 0)
    {
      const gchar *name;
      gboolean en;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&sb)", &name, &en);
      result = cmacs_dispatch_gowl_set_monitor_enabled (name, en, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSetMonitorScale") == 0)
    {
      const gchar *name;
      gdouble scale;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&sd)", &name, &scale);
      result = cmacs_dispatch_gowl_set_monitor_scale (name, scale, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GowlSetMonitorTransform") == 0)
    {
      const gchar *name;
      gint xform;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&si)", &name, &xform);
      result = cmacs_dispatch_gowl_set_monitor_transform (name, xform,
                                                            &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        cmacs_dbus_return_gerror (invocation, err);
    }

#endif /* HAVE_CMACS_GOWL */
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
