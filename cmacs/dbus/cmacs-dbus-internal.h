/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-internal.h --- shared declarations for modules in the
 * cmacs/dbus/ subsystem.  Not part of the public API.
 */

#ifndef CMACS_DBUS_INTERNAL_H
#define CMACS_DBUS_INTERNAL_H

#include "cmacs-dbus.h"

G_BEGIN_DECLS

/* ── Module registration signatures ──────────────────────────────────
 *
 * Each module exposes one register/unregister pair.  The top-level
 * cmacs-dbus.c calls every enabled module's register function once
 * the connection is up, then calls unregister on stop.
 *
 * Register functions return the GDBus registration id (>0) or 0 on
 * failure (with *error set).  Unregister functions take the id back. */

guint    cmacs_dbus_iface_eval_register   (GDBusConnection *conn,
                                            const gchar     *path,
                                            GError         **error);
void     cmacs_dbus_iface_eval_unregister (GDBusConnection *conn, guint id);

#ifdef HAVE_CMACS_GOWL
guint    cmacs_dbus_iface_gowl_register   (GDBusConnection *conn,
                                            const gchar     *path,
                                            GError         **error);
void     cmacs_dbus_iface_gowl_unregister (GDBusConnection *conn, guint id);
#endif

guint    cmacs_dbus_object_manager_register   (GDBusConnection *conn,
                                                const gchar     *path,
                                                GError         **error);
void     cmacs_dbus_object_manager_unregister (GDBusConnection *conn,
                                                guint id);

/* Phase 2 root-level resource manager interfaces. */
guint    cmacs_dbus_iface_bufmgr_register     (GDBusConnection *conn,
                                                const gchar     *path,
                                                GError         **error);
void     cmacs_dbus_iface_bufmgr_unregister   (GDBusConnection *conn, guint id);
guint    cmacs_dbus_iface_framemgr_register   (GDBusConnection *conn,
                                                const gchar     *path,
                                                GError         **error);
void     cmacs_dbus_iface_framemgr_unregister (GDBusConnection *conn, guint id);
guint    cmacs_dbus_iface_winmgr_register     (GDBusConnection *conn,
                                                const gchar     *path,
                                                GError         **error);
void     cmacs_dbus_iface_winmgr_unregister   (GDBusConnection *conn, guint id);
guint    cmacs_dbus_iface_procmgr_register    (GDBusConnection *conn,
                                                const gchar     *path,
                                                GError         **error);
void     cmacs_dbus_iface_procmgr_unregister  (GDBusConnection *conn, guint id);

guint    cmacs_dbus_properties_register   (GDBusConnection *conn,
                                            const gchar     *path,
                                            GError         **error);
void     cmacs_dbus_properties_unregister (GDBusConnection *conn, guint id);

/* Per-property registration.  Modules call this lazily as their objects
 * become live.  GETTER_ELISP is evaluated to read; SETTER_ELISP is a
 * format string with one %s placeholder for the new-value print form
 * (or NULL for read-only).  SIGNATURE is the D-Bus type
 * ("s"/"i"/"u"/"x"/"t"/"d"/"b"/"as"/"av"/...). */
void     cmacs_dbus_register_property     (const gchar *path,
                                            const gchar *iface,
                                            const gchar *name,
                                            const gchar *signature,
                                            const gchar *getter_elisp,
                                            const gchar *setter_elisp);

/* ── Phase 3 iface registration ─────────────────────────────────────
 *
 * Each typed iface module exposes a register/unregister pair.  All
 * registered at /org/cmacs/Editor by cmacs-dbus.c. */

#define CMACS_DBUS_IFACE_DECL(name)                                    \
  guint cmacs_dbus_iface_##name##_register   (GDBusConnection *,       \
                                               const gchar *,           \
                                               GError **);              \
  void  cmacs_dbus_iface_##name##_unregister (GDBusConnection *, guint);

CMACS_DBUS_IFACE_DECL (search)
CMACS_DBUS_IFACE_DECL (vc)
CMACS_DBUS_IFACE_DECL (project)
CMACS_DBUS_IFACE_DECL (cintrospect)
CMACS_DBUS_IFACE_DECL (cpatch)
CMACS_DBUS_IFACE_DECL (bookmark)
CMACS_DBUS_IFACE_DECL (clipboard)
CMACS_DBUS_IFACE_DECL (package)
CMACS_DBUS_IFACE_DECL (file)
CMACS_DBUS_IFACE_DECL (text)
CMACS_DBUS_IFACE_DECL (nav)
CMACS_DBUS_IFACE_DECL (config)

/* ── Generic helper: invoke elisp + return string ───────────────────
 *
 * Builds an elisp expression by substituting %s placeholders with
 * lisp-escape'd argv values, evaluates via cmacs_dispatch_eval, and
 * sends the result as a (s) D-Bus reply (or D-Bus error).
 *
 * Designed for the "elisp emitter style" cmacsgi handlers use. */
void cmacs_dbus_eval_to_reply (GDBusMethodInvocation *invocation,
                               const gchar           *elisp_template,
                               const gchar          **args,
                               gint                   n_args);

/* ── Object Manager: managed-object registry ─────────────────────────
 *
 * Modules that register dynamic objects (Phase 2: buffers, frames,
 * windows) call these helpers so the root ObjectManager can answer
 * GetManagedObjects and emit InterfacesAdded/Removed.
 *
 * Phase 1 keeps these stubs bound to the root path only, but the API
 * is forward-compatible for Phase 2. */

/* Register a (path, iface, GVariant a{sv} of properties) tuple with
 * the ObjectManager.  Emits InterfacesAdded.  Properties may be NULL.
 * Path-iface pairs are unique; re-registering replaces. */
void cmacs_dbus_object_manager_add_iface    (const gchar *path,
                                              const gchar *iface,
                                              GVariant    *properties);

/* Remove (path, iface).  Emits InterfacesRemoved.  No-op if not present. */
void cmacs_dbus_object_manager_remove_iface (const gchar *path,
                                              const gchar *iface);

/* ── Lisp-escape helpers (mirror cmacs/api/cmacs-api-helpers.c) ──────
 *
 * Used by typed-method handlers (Phase 3) when building elisp from
 * argv.  Phase 1 only needs them for ObjectManager body emit. */
gchar *cmacs_dbus_lisp_escape (const gchar *s);
gchar *cmacs_dbus_lisp_quote  (const gchar *s);

/* ── Signal-emit helpers (cmacs-dbus-emit.c) ─────────────────────────
 *
 * Safe to call from any thread that has the cmacs main context as
 * thread-default; the helpers themselves do no Lisp work, just
 * dispatch g_dbus_connection_emit_signal. */

/* Emit ARBITRARY signal at PATH on IFACE.  PARAMS may be NULL or a
 * floating-ref tuple variant (consumed). */
void cmacs_dbus_emit_signal (const gchar *path,
                             const gchar *iface,
                             const gchar *signal_name,
                             GVariant    *params);

/* Emit org.freedesktop.DBus.Properties.PropertiesChanged.
 *   CHANGED:    a{sv} of (name -> new-value).  May be NULL if all
 *               changes are invalidations.  Consumed.
 *   INVALIDATED: array of names invalidated without new value, or NULL. */
void cmacs_dbus_emit_properties_changed (const gchar  *path,
                                         const gchar  *iface,
                                         GVariant     *changed,
                                         const gchar **invalidated);

/* ── Common error helper ─────────────────────────────────────────── */

void cmacs_dbus_return_gerror (GDBusMethodInvocation *invocation,
                               GError                *err);

G_END_DECLS

#endif /* CMACS_DBUS_INTERNAL_H */
