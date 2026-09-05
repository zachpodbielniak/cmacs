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

/* ── MCP-parity ifaces (Phase 6) ────────────────────────────────────
 *
 * One iface per subsystem so every MCP tool capability is reachable
 * over D-Bus (consumed by emacsctl).  Sync discipline: adding a tool
 * in cmacs/mcp/cmacs-mcp-tools-*.c requires a matching method in the
 * paired cmacs-dbus-iface-*.c, and vice versa. */

/* Always available with cmacs-glib. */
CMACS_DBUS_IFACE_DECL (eshell)
CMACS_DBUS_IFACE_DECL (edit)
CMACS_DBUS_IFACE_DECL (input)
CMACS_DBUS_IFACE_DECL (debug)
CMACS_DBUS_IFACE_DECL (instance)
CMACS_DBUS_IFACE_DECL (log)

#ifdef HAVE_CMACS_CRISPY
CMACS_DBUS_IFACE_DECL (crispy)
#endif
#ifdef HAVE_CMACS_BACON
CMACS_DBUS_IFACE_DECL (bacon)
#endif
#ifdef HAVE_CMACS_AI
CMACS_DBUS_IFACE_DECL (ai)
#endif
#ifdef HAVE_CMACS_GSURF
CMACS_DBUS_IFACE_DECL (gsurf)
#endif
#ifdef HAVE_CMACS_GNUSEYE
CMACS_DBUS_IFACE_DECL (gnuseye)
#endif
#ifdef HAVE_CMACS_PODOMATION
CMACS_DBUS_IFACE_DECL (podomation)
#endif
#ifdef HAVE_CMACS_VIDEO
CMACS_DBUS_IFACE_DECL (video)
#endif
#ifdef HAVE_CMACS_AUDIO
CMACS_DBUS_IFACE_DECL (audio)
#endif
#if defined(HAVE_CMACS_WHISPER) || defined(HAVE_CMACS_PIPER)
CMACS_DBUS_IFACE_DECL (speech)
#endif
#ifdef HAVE_CMACS_LIBREGNUM
CMACS_DBUS_IFACE_DECL (lrg)
#endif
#ifdef HAVE_CMACS_CALCULATOR
CMACS_DBUS_IFACE_DECL (calculator)
#endif
#ifdef HAVE_CMACS_DBEXPLORER
CMACS_DBUS_IFACE_DECL (dbexplorer)
#endif
#ifdef HAVE_CMACS_AI_BRIGADE
CMACS_DBUS_IFACE_DECL (brigade)
#endif
#ifdef HAVE_CMACS_SECONDBRAIN
CMACS_DBUS_IFACE_DECL (secondbrain)
#endif

/* Phase 4 desktop integration. */
guint cmacs_dbus_application_register   (GDBusConnection *, const gchar *, GError **);
void  cmacs_dbus_application_unregister (GDBusConnection *, guint);
guint cmacs_dbus_actions_register       (GDBusConnection *, const gchar *, GError **);
void  cmacs_dbus_actions_unregister     (GDBusConnection *, guint);
guint cmacs_dbus_search_provider_register   (GDBusConnection *, const gchar *, GError **);
void  cmacs_dbus_search_provider_unregister (GDBusConnection *, guint);

/* Phase 5 creative extensions. */
guint cmacs_dbus_iface_watch_register   (GDBusConnection *, const gchar *, GError **);
void  cmacs_dbus_iface_watch_unregister (GDBusConnection *, guint);

/* Unified editor events surface (registered at the root path like the
 * other ifaces).  See cmacs-dbus-iface-events.c. */
CMACS_DBUS_IFACE_DECL (events)

#ifdef HAVE_CMACS_GOWL
/* Wayland compositor + display configuration ifaces (replaces the
 * Gowl* methods that previously sat on org.cmacs.Editor1). */
guint cmacs_dbus_iface_compositor_register   (GDBusConnection *, const gchar *, GError **);
void  cmacs_dbus_iface_compositor_unregister (GDBusConnection *, guint);
guint cmacs_dbus_iface_monitor_register      (GDBusConnection *, const gchar *, GError **);
void  cmacs_dbus_iface_monitor_unregister    (GDBusConnection *, guint);
#endif

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

/* Like cmacs_dbus_eval_to_reply but string results are returned
 * verbatim (cmacs_dispatch_eval_string), not prin1-quoted.  For
 * methods surfacing raw text: buffer contents, shell output,
 * generated reports. */
void cmacs_dbus_eval_to_reply_string (GDBusMethodInvocation *invocation,
                                      const gchar           *elisp_template,
                                      const gchar          **args,
                                      gint                   n_args);

/* Substitute %s placeholders in ELISP_TEMPLATE with lisp-escaped ARGS
 * (%% emits a literal %).  Caller g_frees the result.  Shared by the
 * reply helpers above and by handlers that post-process the eval
 * result before replying with a typed signature. */
gchar *cmacs_dbus_build_elisp (const gchar  *elisp_template,
                               const gchar **args,
                               gint          n_args);

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
