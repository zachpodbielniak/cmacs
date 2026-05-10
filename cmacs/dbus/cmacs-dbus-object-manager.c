/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-object-manager.c --- org.freedesktop.DBus.ObjectManager
 *
 * The ObjectManager is registered at /org/cmacs/Editor and answers
 * GetManagedObjects with a snapshot of every (path, iface) tuple that
 * Phase-2+ modules have announced via cmacs_dbus_object_manager_add_iface.
 *
 * Phase 1 ships the registry, vtable, and signal-emit code, but no
 * module adds children yet — GetManagedObjects returns an empty dict.
 * Phase 2 (per-buffer / per-frame / per-window objects) starts
 * populating it.
 *
 * The registry shape is:
 *   path -> iface -> a{sv} of properties (may be empty)
 *
 * GetManagedObjects flattens that into a{oa{sa{sv}}} per the spec
 * (https://dbus.freedesktop.org/doc/dbus-specification.html#standard-interfaces-objectmanager).
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"

#include <gio/gio.h>
#include <string.h>

/* ── Registry ─────────────────────────────────────────────────────── */

/* path (g_strdup) -> GHashTable<iface (g_strdup), GVariant *> */
static GHashTable *managed_objects = NULL;

/* The path the ObjectManager is registered at (set on register).  All
 * managed objects must live under this path (i.e. start with it + "/"). */
static gchar *manager_path = NULL;

static GHashTable *
get_iface_dict (const gchar *path, gboolean create)
{
  GHashTable *ifaces;

  if (managed_objects == NULL)
    {
      if (!create)
        return NULL;
      managed_objects = g_hash_table_new_full (
        g_str_hash, g_str_equal, g_free,
        (GDestroyNotify) g_hash_table_unref);
    }
  ifaces = g_hash_table_lookup (managed_objects, path);
  if (ifaces == NULL && create)
    {
      ifaces = g_hash_table_new_full (
        g_str_hash, g_str_equal, g_free,
        (GDestroyNotify) g_variant_unref);
      g_hash_table_insert (managed_objects, g_strdup (path), ifaces);
    }
  return ifaces;
}

/* ── Public registry API ─────────────────────────────────────────── */

void
cmacs_dbus_object_manager_add_iface (const gchar *path,
                                     const gchar *iface,
                                     GVariant    *properties)
{
  GHashTable *ifaces = get_iface_dict (path, TRUE);
  GVariant *props = properties;

  if (props == NULL)
    props = g_variant_new ("a{sv}", NULL);
  /* Sink+take ownership for storage. */
  g_variant_ref_sink (props);

  g_hash_table_replace (ifaces, g_strdup (iface), props);

  /* Emit InterfacesAdded(path, {iface: a{sv}}). */
  if (manager_path != NULL && cmacs_dbus_get_connection () != NULL)
    {
      GVariantBuilder *outer;
      GVariantBuilder *inner;
      GVariant *added;

      outer = g_variant_builder_new (G_VARIANT_TYPE ("a{sa{sv}}"));
      inner = g_variant_builder_new (G_VARIANT_TYPE ("a{sv}"));
      {
        GVariantIter it;
        const gchar *k;
        GVariant *v;
        g_variant_iter_init (&it, props);
        while (g_variant_iter_next (&it, "{&sv}", &k, &v))
          {
            g_variant_builder_add (inner, "{sv}", k, v);
            g_variant_unref (v);
          }
      }
      g_variant_builder_add (outer, "{sa{sv}}", iface, inner);
      added = g_variant_new ("(oa{sa{sv}})", path, outer);
      cmacs_dbus_emit_signal (manager_path,
                              "org.freedesktop.DBus.ObjectManager",
                              "InterfacesAdded", added);
      g_variant_builder_unref (inner);
      g_variant_builder_unref (outer);
    }
}

void
cmacs_dbus_object_manager_remove_iface (const gchar *path,
                                        const gchar *iface)
{
  GHashTable *ifaces = get_iface_dict (path, FALSE);
  if (ifaces == NULL)
    return;
  if (!g_hash_table_remove (ifaces, iface))
    return;

  /* If no ifaces left at this path, drop the path entry. */
  if (g_hash_table_size (ifaces) == 0)
    g_hash_table_remove (managed_objects, path);

  /* Emit InterfacesRemoved(path, [iface]). */
  if (manager_path != NULL && cmacs_dbus_get_connection () != NULL)
    {
      GVariantBuilder *b = g_variant_builder_new (G_VARIANT_TYPE ("as"));
      g_variant_builder_add (b, "s", iface);
      cmacs_dbus_emit_signal (
        manager_path, "org.freedesktop.DBus.ObjectManager",
        "InterfacesRemoved",
        g_variant_new ("(oas)", path, b));
      g_variant_builder_unref (b);
    }
}

/* ── ObjectManager method handlers ───────────────────────────────── */

static const gchar *object_manager_xml =
  "<node>"
  "  <interface name='org.freedesktop.DBus.ObjectManager'>"
  "    <method name='GetManagedObjects'>"
  "      <arg name='objects' type='a{oa{sa{sv}}}' direction='out'/>"
  "    </method>"
  "    <signal name='InterfacesAdded'>"
  "      <arg name='object_path' type='o'/>"
  "      <arg name='interfaces_and_properties' type='a{sa{sv}}'/>"
  "    </signal>"
  "    <signal name='InterfacesRemoved'>"
  "      <arg name='object_path' type='o'/>"
  "      <arg name='interfaces' type='as'/>"
  "    </signal>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *om_node_info = NULL;

static void
om_method_call (GDBusConnection       *conn,
                const gchar           *sender,
                const gchar           *object_path,
                const gchar           *iface_name,
                const gchar           *method_name,
                GVariant              *parameters,
                GDBusMethodInvocation *invocation,
                gpointer               user_data)
{
  (void) conn; (void) sender; (void) object_path;
  (void) iface_name; (void) parameters; (void) user_data;

  if (g_strcmp0 (method_name, "GetManagedObjects") == 0)
    {
      GVariantBuilder *root_b;
      GHashTableIter path_it;
      gpointer path_k, path_v;

      root_b = g_variant_builder_new (G_VARIANT_TYPE ("a{oa{sa{sv}}}"));

      if (managed_objects != NULL)
        {
          g_hash_table_iter_init (&path_it, managed_objects);
          while (g_hash_table_iter_next (&path_it, &path_k, &path_v))
            {
              const gchar *path = path_k;
              GHashTable *ifaces = path_v;
              GVariantBuilder *iface_b =
                g_variant_builder_new (G_VARIANT_TYPE ("a{sa{sv}}"));
              GHashTableIter iit;
              gpointer ik, iv;

              g_hash_table_iter_init (&iit, ifaces);
              while (g_hash_table_iter_next (&iit, &ik, &iv))
                {
                  /* Stored variant is a{sv}; embed as-is. */
                  g_variant_builder_add (iface_b, "{s@a{sv}}",
                                         (const gchar *) ik,
                                         (GVariant *) iv);
                }
              g_variant_builder_add (root_b, "{oa{sa{sv}}}", path, iface_b);
              g_variant_builder_unref (iface_b);
            }
        }

      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(a{oa{sa{sv}}})", root_b));
      g_variant_builder_unref (root_b);
    }
}

static const GDBusInterfaceVTable om_vtable = {
  om_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_object_manager_register (GDBusConnection *conn,
                                    const gchar     *path,
                                    GError         **error)
{
  guint id;

  if (om_node_info == NULL)
    {
      om_node_info = g_dbus_node_info_new_for_xml (object_manager_xml,
                                                    error);
      if (om_node_info == NULL)
        return 0;
    }

  id = g_dbus_connection_register_object (
    conn, path, om_node_info->interfaces[0],
    &om_vtable, NULL, NULL, error);
  if (id == 0)
    return 0;

  g_free (manager_path);
  manager_path = g_strdup (path);
  return id;
}

void
cmacs_dbus_object_manager_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0)
    g_dbus_connection_unregister_object (conn, id);
  if (managed_objects != NULL)
    {
      g_hash_table_destroy (managed_objects);
      managed_objects = NULL;
    }
  if (om_node_info != NULL)
    {
      g_dbus_node_info_unref (om_node_info);
      om_node_info = NULL;
    }
  g_free (manager_path);
  manager_path = NULL;
}

#endif /* HAVE_CMACS_GLIB */
