/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-monitor.c --- Wayland monitor management.
 *
 * org.cmacs.Editor1.Monitor at /org/cmacs/Editor.  Split from the
 * compositor iface so display configuration is its own surface --
 * mapping nicely to wlr-output-management semantics.
 *
 * Method names use Display-style verbs (List, Info, SetMode, ...)
 * matching the wlroots convention. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#ifdef HAVE_CMACS_GOWL

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Monitor'>"
  "  <method name='List'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='Info'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='Modes'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetMode'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='i' name='width' direction='in'/>"
  "    <arg type='i' name='height' direction='in'/>"
  "    <arg type='i' name='refresh_mhz' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='Position'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetPosition'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='i' name='x' direction='in'/>"
  "    <arg type='i' name='y' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetEnabled'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='b' name='enabled' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetScale'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='d' name='scale' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetTransform'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='i' name='transform' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

#define RETURN_STR(call_)                                              \
  do {                                                                 \
    GError *err = NULL;                                                \
    gchar *result = (call_);                                           \
    if (result != NULL) {                                              \
      g_dbus_method_invocation_return_value (                          \
        iv, g_variant_new ("(s)", result));                            \
      g_free (result);                                                 \
    } else                                                             \
      cmacs_dbus_return_gerror (iv, err);                              \
    return;                                                            \
  } while (0)

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    RETURN_STR (cmacs_dispatch_gowl_list_monitors (&err));
  else if (g_strcmp0 (m, "Info") == 0)
    {
      const gchar *name;
      g_variant_get (p, "(&s)", &name);
      RETURN_STR (cmacs_dispatch_gowl_monitor_info (name, &err));
    }
  else if (g_strcmp0 (m, "Modes") == 0)
    {
      const gchar *name;
      g_variant_get (p, "(&s)", &name);
      RETURN_STR (cmacs_dispatch_gowl_monitor_modes (name, &err));
    }
  else if (g_strcmp0 (m, "SetMode") == 0)
    {
      const gchar *name;
      gint w, h, refresh;
      g_variant_get (p, "(&siii)", &name, &w, &h, &refresh);
      RETURN_STR (cmacs_dispatch_gowl_set_monitor_mode (name, w, h, refresh,
                                                          &err));
    }
  else if (g_strcmp0 (m, "Position") == 0)
    {
      const gchar *name;
      g_variant_get (p, "(&s)", &name);
      RETURN_STR (cmacs_dispatch_gowl_monitor_position (name, &err));
    }
  else if (g_strcmp0 (m, "SetPosition") == 0)
    {
      const gchar *name;
      gint x, y;
      g_variant_get (p, "(&sii)", &name, &x, &y);
      RETURN_STR (cmacs_dispatch_gowl_set_monitor_pos (name, x, y, &err));
    }
  else if (g_strcmp0 (m, "SetEnabled") == 0)
    {
      const gchar *name;
      gboolean en;
      g_variant_get (p, "(&sb)", &name, &en);
      RETURN_STR (cmacs_dispatch_gowl_set_monitor_enabled (name, en, &err));
    }
  else if (g_strcmp0 (m, "SetScale") == 0)
    {
      const gchar *name;
      gdouble scale;
      g_variant_get (p, "(&sd)", &name, &scale);
      RETURN_STR (cmacs_dispatch_gowl_set_monitor_scale (name, scale, &err));
    }
  else if (g_strcmp0 (m, "SetTransform") == 0)
    {
      const gchar *name;
      gint xform;
      g_variant_get (p, "(&si)", &name, &xform);
      RETURN_STR (cmacs_dispatch_gowl_set_monitor_transform (name, xform,
                                                               &err));
    }
}

#undef RETURN_STR

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_monitor_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_monitor_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GOWL */
#endif /* HAVE_CMACS_GLIB */
