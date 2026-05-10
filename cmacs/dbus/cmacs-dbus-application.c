/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-application.c --- org.freedesktop.Application
 *
 * The standard freedesktop "this is an app you can launch and open
 * files in" interface.  See:
 *   https://specifications.freedesktop.org/desktop-entry/latest/dbus.html
 *
 * Methods:
 *   Activate (a{sv} platform_data)
 *     Bring the running cmacs to the foreground (raise-frame).
 *   Open (as uris, a{sv} platform_data)
 *     Open each URI; file:// URIs go through find-file.
 *   ActivateAction (s name, av args, a{sv} platform_data)
 *     Run a named action -- mapped to M-x.
 *
 * Pair with DBusActivatable=true in the .desktop file so file
 * managers and "Open With cmacs" use this path instead of spawning
 * a fresh emacs every time. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"
#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node><interface name='org.freedesktop.Application'>"
  "  <method name='Activate'>"
  "    <arg type='a{sv}' name='platform_data' direction='in'/></method>"
  "  <method name='Open'>"
  "    <arg type='as' name='uris' direction='in'/>"
  "    <arg type='a{sv}' name='platform_data' direction='in'/></method>"
  "  <method name='ActivateAction'>"
  "    <arg type='s' name='action_name' direction='in'/>"
  "    <arg type='av' name='parameter' direction='in'/>"
  "    <arg type='a{sv}' name='platform_data' direction='in'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

/* Convert file://path -> /path; pass-through everything else. */
static gchar *
uri_to_path (const gchar *uri)
{
  if (g_str_has_prefix (uri, "file://"))
    return g_uri_unescape_string (uri + 7, NULL);
  return g_strdup (uri);
}

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Activate") == 0)
    {
      gchar *r = cmacs_dispatch_eval (
        "(progn (when-let ((f (selected-frame))) (raise-frame f)) t)", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_free (r);
      g_dbus_method_invocation_return_value (iv, NULL);
    }
  else if (g_strcmp0 (m, "Open") == 0)
    {
      GVariantIter *it;
      const gchar *uri;
      g_variant_get (p, "(asa{sv})", &it, NULL);
      while (g_variant_iter_next (it, "&s", &uri))
        {
          gchar *path = uri_to_path (uri);
          gchar *escaped = cmacs_dbus_lisp_escape (path);
          gchar *expr = g_strdup_printf ("(find-file \"%s\")", escaped);
          gchar *r = cmacs_dispatch_eval (expr, &err);
          g_free (expr); g_free (escaped); g_free (path);
          if (r) g_free (r); else { g_clear_error (&err); }
        }
      g_variant_iter_free (it);
      g_dbus_method_invocation_return_value (iv, NULL);
    }
  else if (g_strcmp0 (m, "ActivateAction") == 0)
    {
      const gchar *name;
      gchar *escaped, *expr, *r;
      g_variant_get (p, "(&sava{sv})", &name, NULL, NULL);
      escaped = cmacs_dbus_lisp_escape (name);
      /* Action names use D-Bus dot notation; strip prefix dots and
         pass through to M-x as-is. */
      expr = g_strdup_printf (
        "(let ((cmd (intern \"%s\")))"
        " (if (commandp cmd) (call-interactively cmd) (funcall cmd)) t)",
        escaped);
      r = cmacs_dispatch_eval (expr, &err);
      g_free (expr); g_free (escaped);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_free (r);
      g_dbus_method_invocation_return_value (iv, NULL);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_application_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_application_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
