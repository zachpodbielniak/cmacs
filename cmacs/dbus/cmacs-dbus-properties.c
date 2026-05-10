/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-properties.c --- org.freedesktop.DBus.Properties helper
 *
 * Modules call cmacs_dbus_register_property(path, iface, name, sig,
 * getter_elisp, setter_elisp) to declare properties on any path.
 * The first registration at a given path causes the Properties
 * interface vtable to attach to that path.  Get / GetAll / Set
 * evaluate the registered getter/setter expressions through
 * cmacs_dispatch_eval and translate the result through a small
 * type matrix.
 *
 * Phase 1 ships the registry + dispatch but no module registers
 * properties yet; Phase 2 populates it from cmacs-dbus-buffer-obj.c
 * (and frame/window).
 *
 * PropertiesChanged emission goes through cmacs-dbus-emit.c —
 * properties.c is read/write only.  Modules drive change emission
 * from Lisp hooks so the trigger logic stays in Elisp where the
 * relevant signals live.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

/* ── Registry shape ───────────────────────────────────────────────── */

typedef struct
{
  gchar *signature;       /* D-Bus type signature, e.g. "s" / "x" / "as" */
  gchar *getter_elisp;    /* elisp expression returning the value */
  gchar *setter_elisp;    /* elisp expression accepting the new value
                             via %s placeholder, or NULL if read-only */
} PropEntry;

/* path -> (iface -> (name -> PropEntry*)) */
static GHashTable *prop_registry = NULL;

/* path -> registered iface id (Properties vtable) */
static GHashTable *prop_path_regs = NULL;

static void
prop_entry_free (gpointer p)
{
  PropEntry *e = p;
  if (e == NULL) return;
  g_free (e->signature);
  g_free (e->getter_elisp);
  g_free (e->setter_elisp);
  g_free (e);
}

static GHashTable *
get_iface_table_for_path (const gchar *path, gboolean create)
{
  GHashTable *ifaces;
  if (prop_registry == NULL)
    {
      if (!create)
        return NULL;
      prop_registry = g_hash_table_new_full (
        g_str_hash, g_str_equal, g_free,
        (GDestroyNotify) g_hash_table_unref);
    }
  ifaces = g_hash_table_lookup (prop_registry, path);
  if (ifaces == NULL && create)
    {
      ifaces = g_hash_table_new_full (
        g_str_hash, g_str_equal, g_free,
        (GDestroyNotify) g_hash_table_unref);
      g_hash_table_insert (prop_registry, g_strdup (path), ifaces);
    }
  return ifaces;
}

static GHashTable *
get_prop_table (const gchar *path, const gchar *iface, gboolean create)
{
  GHashTable *ifaces = get_iface_table_for_path (path, create);
  GHashTable *props;
  if (ifaces == NULL)
    return NULL;
  props = g_hash_table_lookup (ifaces, iface);
  if (props == NULL && create)
    {
      props = g_hash_table_new_full (
        g_str_hash, g_str_equal, g_free, prop_entry_free);
      g_hash_table_insert (ifaces, g_strdup (iface), props);
    }
  return props;
}

/* ── Type matrix: Lisp printed-value -> GVariant ─────────────────── */

static GVariant *
parse_to_variant (const gchar *signature, const gchar *printed)
{
  /* `printed' is the result of Fprin1_to_string from Lisp; covers all
     primitive cases the property registry actually needs. */
  if (g_strcmp0 (signature, "s") == 0)
    {
      const gchar *s = printed;
      gint len = (gint) strlen (s);
      gchar *unquoted;
      GVariant *v;
      if (len >= 2 && s[0] == '"' && s[len - 1] == '"')
        {
          unquoted = g_strndup (s + 1, len - 2);
          /* Crude unescape \\ and \" --- enough for filenames / mode names. */
          {
            gchar *r = unquoted, *w = unquoted;
            while (*r)
              {
                if (*r == '\\' && (r[1] == '"' || r[1] == '\\'))
                  *w++ = *++r;
                else
                  *w++ = *r;
                r++;
              }
            *w = '\0';
          }
          v = g_variant_new_string (unquoted);
          g_free (unquoted);
          return v;
        }
      return g_variant_new_string (g_strcmp0 (s, "nil") == 0 ? "" : s);
    }
  if (g_strcmp0 (signature, "b") == 0)
    return g_variant_new_boolean (g_strcmp0 (printed, "nil") != 0);
  if (g_strcmp0 (signature, "i") == 0)
    return g_variant_new_int32 ((gint32) g_ascii_strtoll (printed, NULL, 10));
  if (g_strcmp0 (signature, "u") == 0)
    return g_variant_new_uint32 ((guint32) g_ascii_strtoull (printed, NULL, 10));
  if (g_strcmp0 (signature, "x") == 0)
    return g_variant_new_int64 (g_ascii_strtoll (printed, NULL, 10));
  if (g_strcmp0 (signature, "t") == 0)
    return g_variant_new_uint64 (g_ascii_strtoull (printed, NULL, 10));
  if (g_strcmp0 (signature, "d") == 0)
    return g_variant_new_double (g_ascii_strtod (printed, NULL));
  /* Fallback: stringify whatever Lisp produced. */
  return g_variant_new_string (printed ? printed : "");
}

static GVariant *
eval_property (const PropEntry *e)
{
  GError *err = NULL;
  gchar *result = cmacs_dispatch_eval (e->getter_elisp, &err);
  GVariant *v;

  if (result == NULL)
    {
      g_warning ("cmacs-dbus props: getter failed: %s",
                 err ? err->message : "unknown");
      if (err) g_error_free (err);
      return parse_to_variant (e->signature, "nil");
    }
  v = parse_to_variant (e->signature, result);
  g_free (result);
  return v;
}

/* ── Vtable ──────────────────────────────────────────────────────── */

static const gchar *properties_xml =
  "<node>"
  "  <interface name='org.freedesktop.DBus.Properties'>"
  "    <method name='Get'>"
  "      <arg name='interface_name' type='s' direction='in'/>"
  "      <arg name='property_name' type='s' direction='in'/>"
  "      <arg name='value' type='v' direction='out'/>"
  "    </method>"
  "    <method name='Set'>"
  "      <arg name='interface_name' type='s' direction='in'/>"
  "      <arg name='property_name' type='s' direction='in'/>"
  "      <arg name='value' type='v' direction='in'/>"
  "    </method>"
  "    <method name='GetAll'>"
  "      <arg name='interface_name' type='s' direction='in'/>"
  "      <arg name='properties' type='a{sv}' direction='out'/>"
  "    </method>"
  "    <signal name='PropertiesChanged'>"
  "      <arg name='interface_name' type='s'/>"
  "      <arg name='changed_properties' type='a{sv}'/>"
  "      <arg name='invalidated_properties' type='as'/>"
  "    </signal>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *properties_node_info = NULL;

static void
prop_method_call (GDBusConnection       *conn,
                  const gchar           *sender,
                  const gchar           *object_path,
                  const gchar           *iface_name,
                  const gchar           *method_name,
                  GVariant              *parameters,
                  GDBusMethodInvocation *invocation,
                  gpointer               user_data)
{
  (void) conn; (void) sender; (void) iface_name; (void) user_data;

  if (g_strcmp0 (method_name, "Get") == 0)
    {
      const gchar *iface, *name;
      GHashTable *props;
      PropEntry *e;
      GVariant *val;

      g_variant_get (parameters, "(&s&s)", &iface, &name);
      props = get_prop_table (object_path, iface, FALSE);
      e = props ? g_hash_table_lookup (props, name) : NULL;
      if (e == NULL)
        {
          g_dbus_method_invocation_return_dbus_error (
            invocation, "org.freedesktop.DBus.Error.UnknownProperty", name);
          return;
        }
      val = eval_property (e);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(v)", val));
    }
  else if (g_strcmp0 (method_name, "GetAll") == 0)
    {
      const gchar *iface;
      GHashTable *props;
      GVariantBuilder *b;
      GHashTableIter it;
      gpointer k, v;

      g_variant_get (parameters, "(&s)", &iface);
      props = get_prop_table (object_path, iface, FALSE);
      b = g_variant_builder_new (G_VARIANT_TYPE ("a{sv}"));
      if (props != NULL)
        {
          g_hash_table_iter_init (&it, props);
          while (g_hash_table_iter_next (&it, &k, &v))
            {
              const gchar *name = k;
              PropEntry *e = v;
              GVariant *val = eval_property (e);
              g_variant_builder_add (b, "{sv}", name, val);
            }
        }
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(a{sv})", b));
      g_variant_builder_unref (b);
    }
  else if (g_strcmp0 (method_name, "Set") == 0)
    {
      const gchar *iface, *name;
      GVariant *value;
      GHashTable *props;
      PropEntry *e;
      gchar *printed;
      GError *err = NULL;
      gchar *expr, *result;

      g_variant_get (parameters, "(&s&sv)", &iface, &name, &value);
      props = get_prop_table (object_path, iface, FALSE);
      e = props ? g_hash_table_lookup (props, name) : NULL;
      if (e == NULL || e->setter_elisp == NULL)
        {
          g_variant_unref (value);
          g_dbus_method_invocation_return_dbus_error (
            invocation, "org.freedesktop.DBus.Error.PropertyReadOnly", name);
          return;
        }
      /* Marshal the variant body to a Lisp-readable printed form.
         Variant tear-down via g_variant_print is reasonable for the
         types our property matrix understands. */
      printed = g_variant_print (value, FALSE);
      g_variant_unref (value);

      /* Substitute %s in the setter elisp template. */
      expr = g_strdup_printf (e->setter_elisp, printed);
      g_free (printed);

      result = cmacs_dispatch_eval (expr, &err);
      g_free (expr);
      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      g_free (result);
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
}

static const GDBusInterfaceVTable prop_vtable = {
  prop_method_call, NULL, NULL, { NULL }
};

/* ── Public registration API ─────────────────────────────────────── */

static gboolean
ensure_properties_iface_attached (GDBusConnection *conn, const gchar *path)
{
  guint id;
  GError *err = NULL;
  if (prop_path_regs == NULL)
    prop_path_regs = g_hash_table_new_full (
      g_str_hash, g_str_equal, g_free, NULL);
  if (g_hash_table_contains (prop_path_regs, path))
    return TRUE;

  if (properties_node_info == NULL)
    {
      properties_node_info =
        g_dbus_node_info_new_for_xml (properties_xml, &err);
      if (properties_node_info == NULL)
        {
          g_warning ("cmacs-dbus props: introspect: %s",
                     err ? err->message : "unknown");
          if (err) g_error_free (err);
          return FALSE;
        }
    }

  id = g_dbus_connection_register_object (
    conn, path, properties_node_info->interfaces[0],
    &prop_vtable, NULL, NULL, &err);
  if (id == 0)
    {
      g_warning ("cmacs-dbus props: register %s failed: %s",
                 path, err ? err->message : "unknown");
      if (err) g_error_free (err);
      return FALSE;
    }
  g_hash_table_insert (prop_path_regs, g_strdup (path),
                       GUINT_TO_POINTER (id));
  return TRUE;
}

void
cmacs_dbus_register_property (const gchar *path,
                              const gchar *iface,
                              const gchar *name,
                              const gchar *signature,
                              const gchar *getter_elisp,
                              const gchar *setter_elisp)
{
  GDBusConnection *conn = cmacs_dbus_get_connection ();
  GHashTable *props;
  PropEntry *e;

  if (conn == NULL)
    {
      g_warning ("cmacs-dbus props: register %s.%s while not running",
                 iface, name);
      return;
    }

  if (!ensure_properties_iface_attached (conn, path))
    return;

  props = get_prop_table (path, iface, TRUE);
  e = g_new0 (PropEntry, 1);
  e->signature = g_strdup (signature);
  e->getter_elisp = g_strdup (getter_elisp);
  e->setter_elisp = setter_elisp ? g_strdup (setter_elisp) : NULL;
  /* Replace any existing entry. */
  g_hash_table_replace (props, g_strdup (name), e);
}

guint
cmacs_dbus_properties_register (GDBusConnection *conn, const gchar *path,
                                GError **error)
{
  /* No properties to register at root in Phase 1.  Forward-declared
     for module registration parity; no-op until Phase 2. */
  (void) conn; (void) path; (void) error;
  return 0;
}

void
cmacs_dbus_properties_unregister (GDBusConnection *conn, guint id)
{
  /* Per-path unregistration for Phase 2; release everything. */
  GHashTableIter it;
  gpointer k, v;
  (void) id;

  if (prop_path_regs != NULL)
    {
      g_hash_table_iter_init (&it, prop_path_regs);
      while (g_hash_table_iter_next (&it, &k, &v))
        {
          guint pid = GPOINTER_TO_UINT (v);
          if (pid > 0)
            g_dbus_connection_unregister_object (conn, pid);
        }
      g_hash_table_destroy (prop_path_regs);
      prop_path_regs = NULL;
    }
  if (prop_registry != NULL)
    {
      g_hash_table_destroy (prop_registry);
      prop_registry = NULL;
    }
  if (properties_node_info != NULL)
    {
      g_dbus_node_info_unref (properties_node_info);
      properties_node_info = NULL;
    }
}

#endif /* HAVE_CMACS_GLIB */
