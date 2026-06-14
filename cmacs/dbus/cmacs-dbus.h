/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus.h --- public API for the cmacs D-Bus subsystem.
 *
 * The cmacs D-Bus subsystem registers the editor as a session-bus
 * service so external processes can call into Emacs through typed
 * methods, watch live state via Properties / ObjectManager, and
 * receive event notifications via signals.
 *
 * Architecture:
 *
 *   Bus names (dual claim):
 *     org.cmacs.Editor                 -- well-known, primary daemon
 *     org.cmacs.Editor.Pid<N>          -- per-instance, always claimed
 *
 *   Object root:
 *     /org/cmacs/Editor                -- carries multiple interfaces
 *
 *   Standard interfaces:
 *     org.freedesktop.DBus.Introspectable    (auto-provided by GDBus)
 *     org.freedesktop.DBus.Peer              (auto-provided by bus)
 *     org.freedesktop.DBus.Properties        (cmacs-dbus-properties.c)
 *     org.freedesktop.DBus.ObjectManager     (cmacs-dbus-object-manager.c)
 *
 *   Cmacs interfaces (back-compat surface preserved bit-for-bit):
 *     org.cmacs.Editor1                      Eval/FindFile/Message/Gi*
 *                                            + 18 gowl methods (HAVE_CMACS_GOWL)
 *
 * Phase 2-5 add per-buffer / per-frame / per-window object paths,
 * typed cmacsgi-parity interfaces, SearchProvider2, Notifications,
 * Inhibit, MPRIS, etc.
 */

#ifndef CMACS_DBUS_H
#define CMACS_DBUS_H

#include <gio/gio.h>

G_BEGIN_DECLS

/* Object path of the root cmacs editor object. */
#define CMACS_DBUS_ROOT_PATH "/org/cmacs/Editor"

/* Interface name of the events surface.  Registered at the root path
 * like every other cmacs interface, so emacsctl (which calls methods at
 * the root) and the firehose subscribers share one object. */
#define CMACS_DBUS_EVENTS_IFACE "org.cmacs.Editor1.Events"

/* Well-known bus name (dual-claimed at start, may not be acquired if
 * another cmacs instance already owns it). */
#define CMACS_DBUS_WELL_KNOWN_NAME "org.cmacs.Editor"

/* ── Lifecycle ─────────────────────────────────────────────────────── */

/* Start the D-Bus service.  Connects to the session bus on the cmacs
 * GMainContext, registers all enabled interfaces at CMACS_DBUS_ROOT_PATH,
 * and claims org.cmacs.Editor (well-known) plus org.cmacs.Editor.Pid<N>.
 *
 * If the well-known name is already owned by another cmacs instance,
 * starts in per-PID-only mode.  Either way the per-PID name is always
 * acquired so cmacsgi can target a specific instance.
 *
 * Returns the dominant bus name (well-known if acquired, else per-PID).
 * Sets *error and returns NULL on connection failure. */
gchar *cmacs_dbus_start_internal (GError **error);

/* Stop the service: unregister all objects, release bus names,
 * disconnect.  Safe to call when not running. */
void cmacs_dbus_stop_internal (void);

/* TRUE if the service is currently running. */
gboolean cmacs_dbus_is_running (void);

/* ── Connection access (for module registration callbacks) ─────────── */

/* The active D-Bus connection, or NULL if not running.  Modules pass
 * this to g_dbus_connection_register_object / emit_signal. */
GDBusConnection *cmacs_dbus_get_connection (void);

/* ── Bus-name queries ──────────────────────────────────────────────── */

/* The well-known bus name if acquired, else NULL. */
const gchar *cmacs_dbus_get_well_known_name (void);

/* The per-PID bus name (org.cmacs.Editor.Pid<N>), or NULL when stopped. */
const gchar *cmacs_dbus_get_per_pid_name (void);

/* The dominant name to advertise to consumers.  Returns the
 * well-known name when held, otherwise the per-PID name. */
const gchar *cmacs_dbus_get_dominant_name (void);

G_END_DECLS

#endif /* CMACS_DBUS_H */
