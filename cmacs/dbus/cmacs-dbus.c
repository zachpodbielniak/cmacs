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
static guint reg_iface_bufmgr   = 0;
static guint reg_iface_framemgr = 0;
static guint reg_iface_winmgr   = 0;
static guint reg_iface_procmgr  = 0;
/* Phase 3 typed parity ifaces. */
static guint reg_iface_search   = 0;
static guint reg_iface_vc       = 0;
static guint reg_iface_project  = 0;
static guint reg_iface_cintrospect = 0;
static guint reg_iface_cpatch   = 0;
static guint reg_iface_bookmark = 0;
static guint reg_iface_clipboard = 0;
static guint reg_iface_package  = 0;
static guint reg_iface_file     = 0;
static guint reg_iface_text     = 0;
static guint reg_iface_nav      = 0;
static guint reg_iface_config   = 0;
/* Phase 4 desktop integration. */
static guint reg_application    = 0;
static guint reg_actions        = 0;
static guint reg_search_provider = 0;
static guint reg_iface_watch    = 0;
#ifdef HAVE_CMACS_GOWL
static guint reg_iface_compositor = 0;
static guint reg_iface_monitor    = 0;
#endif

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

  /* Phase 2: resource manager interfaces. */
  reg_iface_bufmgr = cmacs_dbus_iface_bufmgr_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_bufmgr == 0)
    return FALSE;

  reg_iface_framemgr = cmacs_dbus_iface_framemgr_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_framemgr == 0)
    return FALSE;

  reg_iface_winmgr = cmacs_dbus_iface_winmgr_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_winmgr == 0)
    return FALSE;

  reg_iface_procmgr = cmacs_dbus_iface_procmgr_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_procmgr == 0)
    return FALSE;

  /* Phase 3: cmacsgi parity. */
  reg_iface_search = cmacs_dbus_iface_search_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_search == 0) return FALSE;

  reg_iface_vc = cmacs_dbus_iface_vc_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_vc == 0) return FALSE;

  reg_iface_project = cmacs_dbus_iface_project_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_project == 0) return FALSE;

  reg_iface_cintrospect = cmacs_dbus_iface_cintrospect_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_cintrospect == 0) return FALSE;

  reg_iface_cpatch = cmacs_dbus_iface_cpatch_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_cpatch == 0) return FALSE;

  reg_iface_bookmark = cmacs_dbus_iface_bookmark_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_bookmark == 0) return FALSE;

  reg_iface_clipboard = cmacs_dbus_iface_clipboard_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_clipboard == 0) return FALSE;

  reg_iface_package = cmacs_dbus_iface_package_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_package == 0) return FALSE;

  reg_iface_file = cmacs_dbus_iface_file_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_file == 0) return FALSE;

  reg_iface_text = cmacs_dbus_iface_text_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_text == 0) return FALSE;

  reg_iface_nav = cmacs_dbus_iface_nav_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_nav == 0) return FALSE;

  reg_iface_config = cmacs_dbus_iface_config_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_config == 0) return FALSE;

  /* Phase 4: desktop integration. */
  reg_application = cmacs_dbus_application_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_application == 0) return FALSE;

  reg_actions = cmacs_dbus_actions_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_actions == 0) return FALSE;

  /* SearchProvider2 lives at its own object path. */
  reg_search_provider = cmacs_dbus_search_provider_register (
    conn, CMACS_DBUS_ROOT_PATH "/SearchProvider", error);
  if (reg_search_provider == 0) return FALSE;

  /* Phase 5: creative extensions (root-level Watch iface).  MPRIS is
     opt-in via cmacs-dbus-mpris-start so we don't auto-claim
     org.mpris.MediaPlayer2.cmacs at startup. */
  reg_iface_watch = cmacs_dbus_iface_watch_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_watch == 0) return FALSE;

#ifdef HAVE_CMACS_GOWL
  reg_iface_compositor = cmacs_dbus_iface_compositor_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_compositor == 0) return FALSE;

  reg_iface_monitor = cmacs_dbus_iface_monitor_register (
    conn, CMACS_DBUS_ROOT_PATH, error);
  if (reg_iface_monitor == 0) return FALSE;
#endif

  return TRUE;
}

static void
unregister_modules (GDBusConnection *conn)
{
#ifdef HAVE_CMACS_GOWL
  if (reg_iface_monitor)
    { cmacs_dbus_iface_monitor_unregister (conn, reg_iface_monitor);
      reg_iface_monitor = 0; }
  if (reg_iface_compositor)
    { cmacs_dbus_iface_compositor_unregister (conn, reg_iface_compositor);
      reg_iface_compositor = 0; }
#endif
  if (reg_iface_watch)
    { cmacs_dbus_iface_watch_unregister (conn, reg_iface_watch);
      reg_iface_watch = 0; }
  if (reg_search_provider)
    { cmacs_dbus_search_provider_unregister (conn, reg_search_provider);
      reg_search_provider = 0; }
  if (reg_actions)
    { cmacs_dbus_actions_unregister (conn, reg_actions);
      reg_actions = 0; }
  if (reg_application)
    { cmacs_dbus_application_unregister (conn, reg_application);
      reg_application = 0; }
  if (reg_iface_config)
    { cmacs_dbus_iface_config_unregister (conn, reg_iface_config);
      reg_iface_config = 0; }
  if (reg_iface_nav)
    { cmacs_dbus_iface_nav_unregister (conn, reg_iface_nav);
      reg_iface_nav = 0; }
  if (reg_iface_text)
    { cmacs_dbus_iface_text_unregister (conn, reg_iface_text);
      reg_iface_text = 0; }
  if (reg_iface_file)
    { cmacs_dbus_iface_file_unregister (conn, reg_iface_file);
      reg_iface_file = 0; }
  if (reg_iface_package)
    { cmacs_dbus_iface_package_unregister (conn, reg_iface_package);
      reg_iface_package = 0; }
  if (reg_iface_clipboard)
    { cmacs_dbus_iface_clipboard_unregister (conn, reg_iface_clipboard);
      reg_iface_clipboard = 0; }
  if (reg_iface_bookmark)
    { cmacs_dbus_iface_bookmark_unregister (conn, reg_iface_bookmark);
      reg_iface_bookmark = 0; }
  if (reg_iface_cpatch)
    { cmacs_dbus_iface_cpatch_unregister (conn, reg_iface_cpatch);
      reg_iface_cpatch = 0; }
  if (reg_iface_cintrospect)
    { cmacs_dbus_iface_cintrospect_unregister (conn, reg_iface_cintrospect);
      reg_iface_cintrospect = 0; }
  if (reg_iface_project)
    { cmacs_dbus_iface_project_unregister (conn, reg_iface_project);
      reg_iface_project = 0; }
  if (reg_iface_vc)
    { cmacs_dbus_iface_vc_unregister (conn, reg_iface_vc);
      reg_iface_vc = 0; }
  if (reg_iface_search)
    { cmacs_dbus_iface_search_unregister (conn, reg_iface_search);
      reg_iface_search = 0; }
  if (reg_iface_procmgr)
    { cmacs_dbus_iface_procmgr_unregister (conn, reg_iface_procmgr);
      reg_iface_procmgr = 0; }
  if (reg_iface_winmgr)
    { cmacs_dbus_iface_winmgr_unregister (conn, reg_iface_winmgr);
      reg_iface_winmgr = 0; }
  if (reg_iface_framemgr)
    { cmacs_dbus_iface_framemgr_unregister (conn, reg_iface_framemgr);
      reg_iface_framemgr = 0; }
  if (reg_iface_bufmgr)
    { cmacs_dbus_iface_bufmgr_unregister (conn, reg_iface_bufmgr);
      reg_iface_bufmgr = 0; }
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
extern void syms_of_cmacs_dbus_mpris (void);

void
syms_of_cmacs_dbus (void)
{
  defsubr (&Scmacs_dbus_start);
  defsubr (&Scmacs_dbus_stop);
  defsubr (&Scmacs_dbus_name);
  defsubr (&Scmacs_dbus_well_known_name);
  defsubr (&Scmacs_dbus_per_pid_name);

  syms_of_cmacs_dbus_emit ();
  syms_of_cmacs_dbus_mpris ();
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
