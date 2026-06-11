/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-transport-dbus.c --- CtlTransport over the local session bus.
 *
 * Every call uses G_DBUS_CALL_FLAGS_NO_AUTO_START and enumeration
 * uses ListNames (never ListActivatableNames), so emacsctl can never
 * accidentally D-Bus-activate a new editor. */

#include "ctl-transport-dbus.h"
#include "ctl-ifaces.h"

#include <stdlib.h>
#include <string.h>

struct _CtlDbusTransport
{
  GObject parent_instance;

  GDBusConnection *conn;
  gchar *bus_name;
};

static void ctl_dbus_transport_transport_init (CtlTransportInterface *iface);

G_DEFINE_TYPE_WITH_CODE (CtlDbusTransport, ctl_dbus_transport,
                         G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (CTL_TYPE_TRANSPORT,
                           ctl_dbus_transport_transport_init))

/* ── Instance enumeration ──────────────────────────────────────────── */

/* NULL-terminated PID strings of org.cmacs.Editor.Pid* names on CONN. */
static gchar **
dbus_list_pids (GDBusConnection *conn, GError **error)
{
  GVariant *reply;
  GVariantIter *iter;
  const gchar *name;
  GPtrArray *pids;

  reply = g_dbus_connection_call_sync (
    conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
    "org.freedesktop.DBus", "ListNames", NULL,
    G_VARIANT_TYPE ("(as)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, error);
  if (reply == NULL)
    return NULL;

  pids = g_ptr_array_new ();
  g_variant_get (reply, "(as)", &iter);
  while (g_variant_iter_loop (iter, "&s", &name))
    if (g_str_has_prefix (name, CTL_BUS_PID_PREFIX))
      g_ptr_array_add (pids,
                       g_strdup (name + strlen (CTL_BUS_PID_PREFIX)));
  g_variant_iter_free (iter);
  g_variant_unref (reply);

  g_ptr_array_add (pids, NULL);
  return (gchar **) g_ptr_array_free (pids, FALSE);
}

static gboolean
dbus_name_has_owner (GDBusConnection *conn, const gchar *name)
{
  GVariant *reply;
  gboolean owned = FALSE;

  reply = g_dbus_connection_call_sync (
    conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
    "org.freedesktop.DBus", "NameHasOwner",
    g_variant_new ("(s)", name),
    G_VARIANT_TYPE ("(b)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL);
  if (reply != NULL)
    {
      g_variant_get (reply, "(b)", &owned);
      g_variant_unref (reply);
    }
  return owned;
}

/* Kernel start time (clock ticks since boot) of PID, from
 * /proc/<pid>/stat field 22.  0 on any failure --- the caller falls
 * back to comparing the numeric PIDs. */
static guint64
proc_start_time (const gchar *pid)
{
  gchar *path;
  gchar *contents = NULL;
  gchar *p;
  guint64 start = 0;
  gint field;

  path = g_strdup_printf ("/proc/%s/stat", pid);
  if (!g_file_get_contents (path, &contents, NULL, NULL))
    {
      g_free (path);
      return 0;
    }
  g_free (path);

  /* comm (field 2) may contain spaces; skip past its closing paren,
   * then count space-separated fields: state is 3, starttime is 22. */
  p = strrchr (contents, ')');
  if (p != NULL)
    {
      p++;
      for (field = 3; *p != '\0' && field < 22; field++)
        {
          while (*p == ' ')
            p++;
          while (*p != '\0' && *p != ' ')
            p++;
        }
      while (*p == ' ')
        p++;
      start = g_ascii_strtoull (p, NULL, 10);
    }
  g_free (contents);
  return start;
}

/* The most recently started PID in PIDS (NULL-terminated, len >= 1).
 * Prefers kernel start time; falls back to the highest numeric PID
 * when /proc is unavailable (e.g. a non-Linux host). */
static const gchar *
newest_pid (gchar **pids)
{
  const gchar *best = pids[0];
  guint64 best_start = proc_start_time (pids[0]);
  guint64 best_num = g_ascii_strtoull (pids[0], NULL, 10);
  guint k;

  for (k = 1; pids[k] != NULL; k++)
    {
      guint64 start = proc_start_time (pids[k]);
      guint64 num = g_ascii_strtoull (pids[k], NULL, 10);
      if (start > best_start
          || (start == best_start && num > best_num))
        {
          best = pids[k];
          best_start = start;
          best_num = num;
        }
    }
  return best;
}

/* Resolve SELECTOR to a bus name (caller g_frees), or NULL+error. */
static gchar *
resolve_bus_name (GDBusConnection *conn, const gchar *selector,
                  GError **error)
{
  const gchar *env;

  if (selector != NULL && g_strcmp0 (selector, "auto") != 0
      && *selector != '\0')
    {
      if (g_strcmp0 (selector, "primary") == 0)
        return g_strdup (CTL_BUS_WELL_KNOWN);
      if (g_ascii_isdigit (selector[0]))
        return g_strdup_printf ("%s%s", CTL_BUS_PID_PREFIX, selector);
      /* A full bus name is also accepted. */
      if (g_str_has_prefix (selector, "org.cmacs."))
        return g_strdup (selector);
      g_set_error (error, CTL_ERROR, CTL_ERROR_NO_INSTANCE,
                   "invalid instance selector '%s' "
                   "(expected a PID, 'primary', or 'auto')", selector);
      return NULL;
    }

  env = g_getenv ("CMACS_DBUS_NAME");
  if (env != NULL && *env != '\0')
    return g_strdup (env);

  {
    gchar **pids = dbus_list_pids (conn, error);
    gchar *name = NULL;
    guint n;

    if (pids == NULL)
      return NULL;
    n = g_strv_length (pids);
    if (n == 1)
      name = g_strdup_printf ("%s%s", CTL_BUS_PID_PREFIX, pids[0]);
    else if (n > 1)
      /* Several editors running: default to the newest one. */
      name = g_strdup_printf ("%s%s", CTL_BUS_PID_PREFIX,
                              newest_pid (pids));
    else if (dbus_name_has_owner (conn, CTL_BUS_WELL_KNOWN))
      /* Shouldn't happen (every instance claims a Pid* name), but if
       * something owns the well-known name, honor it. */
      name = g_strdup (CTL_BUS_WELL_KNOWN);
    else
      g_set_error (error, CTL_ERROR, CTL_ERROR_NO_INSTANCE,
                   "no running cmacs instance found on the session bus");
    g_strfreev (pids);
    return name;
  }
}

/* ── CtlTransport implementation ───────────────────────────────────── */

static GVariant *
dbus_call (CtlTransport *transport, const gchar *iface,
           const gchar *method, GVariant *params, gint timeout_ms,
           GError **error)
{
  CtlDbusTransport *self = CTL_DBUS_TRANSPORT (transport);
  return g_dbus_connection_call_sync (
    self->conn, self->bus_name, CTL_OBJECT_PATH, iface, method, params,
    NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, timeout_ms, NULL, error);
}

typedef struct
{
  CtlTransport *transport;     /* unowned (subscription outlives never) */
  CtlTransportSignalFunc cb;
  gpointer user_data;
  GDestroyNotify destroy;
} DbusSubscription;

static void
dbus_signal_trampoline (GDBusConnection *conn, const gchar *sender,
                        const gchar *path, const gchar *iface,
                        const gchar *signal_name, GVariant *args,
                        gpointer user_data)
{
  DbusSubscription *sub = user_data;
  (void) conn; (void) sender; (void) path;
  sub->cb (sub->transport, iface, signal_name, args, sub->user_data);
}

static void
dbus_subscription_free (gpointer data)
{
  DbusSubscription *sub = data;
  if (sub->destroy != NULL)
    sub->destroy (sub->user_data);
  g_free (sub);
}

static guint
dbus_subscribe (CtlTransport *transport, const gchar *iface,
                const gchar *signal_name, CtlTransportSignalFunc cb,
                gpointer user_data, GDestroyNotify destroy)
{
  CtlDbusTransport *self = CTL_DBUS_TRANSPORT (transport);
  DbusSubscription *sub = g_new0 (DbusSubscription, 1);

  sub->transport = transport;
  sub->cb = cb;
  sub->user_data = user_data;
  sub->destroy = destroy;

  /* Match on the target's name: gdbus resolves well-known names to
   * the current owner for us. */
  return g_dbus_connection_signal_subscribe (
    self->conn, self->bus_name, iface, signal_name, CTL_OBJECT_PATH,
    NULL, G_DBUS_SIGNAL_FLAGS_NONE, dbus_signal_trampoline,
    sub, dbus_subscription_free);
}

static void
dbus_unsubscribe (CtlTransport *transport, guint id)
{
  CtlDbusTransport *self = CTL_DBUS_TRANSPORT (transport);
  g_dbus_connection_signal_unsubscribe (self->conn, id);
}

static gchar **
dbus_transport_list_instances (CtlTransport *transport, GError **error)
{
  CtlDbusTransport *self = CTL_DBUS_TRANSPORT (transport);
  return dbus_list_pids (self->conn, error);
}

static void
dbus_close (CtlTransport *transport)
{
  CtlDbusTransport *self = CTL_DBUS_TRANSPORT (transport);
  if (self->conn != NULL)
    {
      g_object_unref (self->conn);
      self->conn = NULL;
    }
}

static void
ctl_dbus_transport_transport_init (CtlTransportInterface *iface)
{
  iface->call = dbus_call;
  iface->subscribe = dbus_subscribe;
  iface->unsubscribe = dbus_unsubscribe;
  iface->list_instances = dbus_transport_list_instances;
  iface->close = dbus_close;
}

/* ── GObject boilerplate ───────────────────────────────────────────── */

static void
ctl_dbus_transport_finalize (GObject *object)
{
  CtlDbusTransport *self = CTL_DBUS_TRANSPORT (object);
  g_clear_object (&self->conn);
  g_free (self->bus_name);
  G_OBJECT_CLASS (ctl_dbus_transport_parent_class)->finalize (object);
}

static void
ctl_dbus_transport_class_init (CtlDbusTransportClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ctl_dbus_transport_finalize;
}

static void
ctl_dbus_transport_init (CtlDbusTransport *self)
{
  (void) self;
}

CtlDbusTransport *
ctl_dbus_transport_new (const gchar *selector, GError **error)
{
  GDBusConnection *conn;
  gchar *bus_name;
  CtlDbusTransport *self;

  conn = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, error);
  if (conn == NULL)
    return NULL;

  bus_name = resolve_bus_name (conn, selector, error);
  if (bus_name == NULL)
    {
      g_object_unref (conn);
      return NULL;
    }

  self = g_object_new (CTL_TYPE_DBUS_TRANSPORT, NULL);
  self->conn = conn;
  self->bus_name = bus_name;
  return self;
}

const gchar *
ctl_dbus_transport_get_bus_name (CtlDbusTransport *self)
{
  return self->bus_name;
}
