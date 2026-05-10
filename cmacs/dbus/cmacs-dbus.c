/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus.c --- top-level lifecycle for the cmacs D-Bus subsystem.
 *
 * Replaces cmacs/glib/cmacs-dbus-service.c.  Owns the session-bus
 * connection, claims both the well-known name org.cmacs.Editor and a
 * per-instance org.cmacs.Editor.Pid<N>, and orchestrates per-module
 * registration at /org/cmacs/Editor.
 *
 * Bus-name strategy (mirrors emacsclient's daemon-vs-instance model):
 *
 *   1. Always acquire org.cmacs.Editor.Pid<N> with REPLACE|DO_NOT_QUEUE.
 *      This name is unique to this process and never conflicts.
 *   2. Try to acquire org.cmacs.Editor (well-known) with the same flags
 *      and ALLOW_REPLACEMENT.  If acquired we are the primary daemon;
 *      external tools can target us as "the cmacs".  If not, another
 *      instance already owns the well-known name and we run in
 *      per-PID-only mode.
 *   3. Listeners on the bus may interact with this process via either
 *      name.  Property / signal emission goes out on whatever
 *      destination the bus assigns to the connection (the unique
 *      :1.NN), so subscribers on either name see them.
 *
 * Per-module registration:
 *
 *   Each enabled module owns its own files under cmacs/dbus/ and
 *   exposes a register/unregister pair (declared in
 *   cmacs-dbus-internal.h).  This file calls each enabled module's
 *   register on start, stashes the registration ID, and unregisters
 *   in reverse order on stop.
 *
 *   Phase 1 enables: ObjectManager, Properties (lazy), iface-eval.
 *   Phase 2-5 will add per-resource objects, typed parity ifaces,
 *   desktop-integration ifaces, and creative extensions, all by
 *   adding more module register calls here.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-glib-loop.h"
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"

#include <gio/gio.h>
#include <unistd.h>
#include <string.h>

/* ── State ─────────────────────────────────────────────────────────── */

static GDBusConnection *dbus_conn        = NULL;
static gchar           *bus_name_well    = NULL;   /* g_strdup'd, NULL if not held */
static gchar           *bus_name_per_pid = NULL;   /* g_strdup'd, always set when running */
static guint            owner_id_well    = 0;
static guint            owner_id_per_pid = 0;

/* Per-module registration ids. */
static guint reg_iface_eval     = 0;
static guint reg_object_manager = 0;
static guint reg_properties     = 0;

/* ── Public connection / name accessors ─────────────────────────── */

GDBusConnection *
cmacs_dbus_get_connection (void)
{
  return dbus_conn;
}

const gchar *
cmacs_dbus_get_well_known_name (void)
{
  return bus_name_well;
}

const gchar *
cmacs_dbus_get_per_pid_name (void)
{
  return bus_name_per_pid;
}

const gchar *
cmacs_dbus_get_dominant_name (void)
{
  return bus_name_well != NULL ? bus_name_well : bus_name_per_pid;
}

gboolean
cmacs_dbus_is_running (void)
{
  return dbus_conn != NULL;
}

/* ── Bus-name owner callbacks ─────────────────────────────────────── */

static void
on_well_known_acquired (GDBusConnection *conn, const gchar *name,
                        gpointer user_data)
{
  (void) conn; (void) user_data;
  /* Already recorded in bus_name_well; no further action needed. */
  g_debug ("cmacs-dbus: acquired well-known name %s", name);
}

static void
on_well_known_lost (GDBusConnection *conn, const gchar *name,
                    gpointer user_data)
{
  (void) conn; (void) user_data;
  /* Either we never got it (another cmacs holds it) or we were
   * replaced.  Drop our cached copy so dominant-name queries fall
   * back to the per-PID name. */
  if (bus_name_well != NULL)
    {
      g_debug ("cmacs-dbus: lost well-known name %s", name);
      g_free (bus_name_well);
      bus_name_well = NULL;
    }
}

static void
on_per_pid_acquired (GDBusConnection *conn, const gchar *name,
                     gpointer user_data)
{
  (void) conn; (void) name; (void) user_data;
}

static void
on_per_pid_lost (GDBusConnection *conn, const gchar *name,
                 gpointer user_data)
{
  (void) conn; (void) user_data;
  g_warning ("cmacs-dbus: unexpectedly lost per-PID name %s", name);
}

/* ── Module registration helpers ───────────────────────────────── */

static gboolean
register_modules (GDBusConnection *conn, GError **error)
{
  reg_iface_eval = cmacs_dbus_iface_eval_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_eval == 0)
    return FALSE;

  reg_object_manager = cmacs_dbus_object_manager_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_object_manager == 0)
    return FALSE;

  /* Properties is lazy --- registers the iface vtable on first
   * cmacs_dbus_register_property call.  No-op here in Phase 1. */
  reg_properties = cmacs_dbus_properties_register (
    conn, CMACS_DBUS_ROOT_PATH, NULL);

  return TRUE;
}

static void
unregister_modules (GDBusConnection *conn)
{
  if (reg_properties)
    {
      cmacs_dbus_properties_unregister (conn, reg_properties);
      reg_properties = 0;
    }
  if (reg_object_manager)
    {
      cmacs_dbus_object_manager_unregister (conn, reg_object_manager);
      reg_object_manager = 0;
    }
  if (reg_iface_eval)
    {
      cmacs_dbus_iface_eval_unregister (conn, reg_iface_eval);
      reg_iface_eval = 0;
    }
}

/* ── Lifecycle ─────────────────────────────────────────────────────── */

gchar *
cmacs_dbus_start_internal (GError **error)
{
  GMainContext *ctx;
  gchar *addr;
  GError *err = NULL;

  if (dbus_conn != NULL)
    return g_strdup (cmacs_dbus_get_dominant_name ());

  ctx = cmacs_glib_get_context ();
  if (ctx == NULL)
    {
      g_set_error (error, g_quark_from_static_string ("cmacs-dbus"),
                   1, "CMacs GLib context not initialized");
      return NULL;
    }

  addr = g_dbus_address_get_for_bus_sync (G_BUS_TYPE_SESSION, NULL, &err);
  if (addr == NULL)
    {
      g_propagate_error (error, err);
      return NULL;
    }

  g_main_context_push_thread_default (ctx);
  dbus_conn = g_dbus_connection_new_for_address_sync (
    addr,
      G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT
    | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
    NULL, NULL, &err);
  g_main_context_pop_thread_default (ctx);
  g_free (addr);

  if (dbus_conn == NULL)
    {
      g_propagate_error (error, err);
      return NULL;
    }

  /* Register each enabled module.  Errors abort start. */
  if (!register_modules (dbus_conn, error))
    {
      unregister_modules (dbus_conn);
      g_object_unref (dbus_conn);
      dbus_conn = NULL;
      return NULL;
    }

  /* Always claim per-PID. */
  bus_name_per_pid = g_strdup_printf ("org.cmacs.Editor.Pid%d",
                                      (int) getpid ());
  owner_id_per_pid = g_bus_own_name_on_connection (
    dbus_conn, bus_name_per_pid,
      G_BUS_NAME_OWNER_FLAGS_REPLACE
    | G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE,
    on_per_pid_acquired, on_per_pid_lost, NULL, NULL);

  /* Try to claim the well-known name.  If another cmacs already owns
   * it the bus enqueues us with ALLOW_REPLACEMENT off → never acquired,
   * but we keep running on per-PID.  We optimistically assume success
   * and clear bus_name_well in the lost callback if we don't get it. */
  bus_name_well = g_strdup (CMACS_DBUS_WELL_KNOWN_NAME);
  owner_id_well = g_bus_own_name_on_connection (
    dbus_conn, CMACS_DBUS_WELL_KNOWN_NAME,
    G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE,
    on_well_known_acquired, on_well_known_lost, NULL, NULL);

  return g_strdup (cmacs_dbus_get_dominant_name ());
}

void
cmacs_dbus_stop_internal (void)
{
  if (dbus_conn == NULL)
    return;

  if (owner_id_well > 0)
    {
      g_bus_unown_name (owner_id_well);
      owner_id_well = 0;
    }
  if (owner_id_per_pid > 0)
    {
      g_bus_unown_name (owner_id_per_pid);
      owner_id_per_pid = 0;
    }

  unregister_modules (dbus_conn);

  g_object_unref (dbus_conn);
  dbus_conn = NULL;

  g_free (bus_name_well);
  bus_name_well = NULL;
  g_free (bus_name_per_pid);
  bus_name_per_pid = NULL;
}

/* ── DEFUNs ──────────────────────────────────────────────────────── */

DEFUN ("cmacs-dbus-start", Fcmacs_dbus_start,
       Scmacs_dbus_start, 0, 0, 0,
       doc: /* Start the CMacs D-Bus service.
Returns the dominant bus name (well-known org.cmacs.Editor if
acquired, else the per-PID org.cmacs.Editor.PidN fallback).

The service exposes the org.cmacs.Editor1 interface for back-compat
plus org.freedesktop.DBus.Properties (lazy) and ObjectManager at
/org/cmacs/Editor for standards-compliant introspection.

Phase 2-5 add per-resource objects (Buffer/Frame/Window) and typed
parity interfaces (Buffer.Insert, VC.Status, etc.) under the same
root.  */)
  (void)
{
  GError *err = NULL;
  gchar *name;

  name = cmacs_dbus_start_internal (&err);
  if (name == NULL)
    {
      gchar *msg = err ? g_strdup (err->message) : g_strdup ("unknown error");
      if (err) g_error_free (err);
      error ("cmacs-dbus-start: %s", msg);
    }

  {
    Lisp_Object lname = build_string (name);
    g_free (name);
    return lname;
  }
}

DEFUN ("cmacs-dbus-stop", Fcmacs_dbus_stop,
       Scmacs_dbus_stop, 0, 0, 0,
       doc: /* Stop the CMacs D-Bus service.
Releases bus names and tears down all registered objects.  Returns t
if the service was running, nil otherwise.  */)
  (void)
{
  if (!cmacs_dbus_is_running ())
    return Qnil;
  cmacs_dbus_stop_internal ();
  return Qt;
}

DEFUN ("cmacs-dbus-name", Fcmacs_dbus_name,
       Scmacs_dbus_name, 0, 0, 0,
       doc: /* Return the dominant D-Bus bus name of the CMacs service,
or nil if not running.  */)
  (void)
{
  const gchar *name = cmacs_dbus_get_dominant_name ();
  if (name == NULL)
    return Qnil;
  return build_string (name);
}

DEFUN ("cmacs-dbus-well-known-name", Fcmacs_dbus_well_known_name,
       Scmacs_dbus_well_known_name, 0, 0, 0,
       doc: /* Return the well-known D-Bus name org.cmacs.Editor if held,
or nil if either the service is stopped or another cmacs instance
already owns the well-known name.  */)
  (void)
{
  const gchar *name = cmacs_dbus_get_well_known_name ();
  return name ? build_string (name) : Qnil;
}

DEFUN ("cmacs-dbus-per-pid-name", Fcmacs_dbus_per_pid_name,
       Scmacs_dbus_per_pid_name, 0, 0, 0,
       doc: /* Return the per-instance D-Bus name org.cmacs.Editor.PidN
for this cmacs process, or nil if the service is stopped.  */)
  (void)
{
  const gchar *name = cmacs_dbus_get_per_pid_name ();
  return name ? build_string (name) : Qnil;
}

extern void syms_of_cmacs_dbus_emit (void);

void
syms_of_cmacs_dbus (void)
{
  defsubr (&Scmacs_dbus_start);
  defsubr (&Scmacs_dbus_stop);
  defsubr (&Scmacs_dbus_name);
  defsubr (&Scmacs_dbus_well_known_name);
  defsubr (&Scmacs_dbus_per_pid_name);

  syms_of_cmacs_dbus_emit ();
}

/* Called once at startup from src/emacs.c::main, after
 * init_cmacs_glib has set up the GMainContext.
 *
 * Auto-starts the D-Bus service in interactive mode so the editor is
 * reachable on the session bus the moment it finishes loading.
 *
 * Skips:
 *   - batch mode (--batch / --script): no GMainContext loop running
 *   - when CMACS_DBUS_NO_AUTOSTART is set in the environment: opt-out
 *     for tests, scripts, or users who prefer to call
 *     cmacs-dbus-start themselves.
 *
 * Failures (no session bus, name claim refused, etc.) are logged as
 * warnings but do NOT abort emacs startup --- the editor still works
 * without the D-Bus surface, and the user can retry with M-: (cmacs-dbus-start). */
void
init_cmacs_dbus (void)
{
  GError *err = NULL;
  gchar *name;

  if (noninteractive)
    return;

  if (g_getenv ("CMACS_DBUS_NO_AUTOSTART") != NULL)
    return;

  name = cmacs_dbus_start_internal (&err);
  if (name == NULL)
    {
      g_warning ("cmacs-dbus: auto-start failed: %s",
                 err ? err->message : "unknown");
      if (err) g_error_free (err);
      return;
    }
  g_free (name);
}

#endif /* HAVE_CMACS_GLIB */
