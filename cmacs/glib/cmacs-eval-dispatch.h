/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-eval-dispatch.h — shared dispatch for CMacs eval operations
 *
 * Pure C dispatch layer used by both the D-Bus service and the
 * socketpair IPC handler.  All functions run on the Emacs main thread.
 */

#ifndef CMACS_EVAL_DISPATCH_H
#define CMACS_EVAL_DISPATCH_H

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include <glib.h>

/* Evaluate EXPRESSION as elisp.  On success, return the printed
   result (caller must g_free).  On error, set *ERROR and return NULL. */
gchar *cmacs_dispatch_eval (const gchar *expression, GError **error);

/* Evaluate EXPRESSION as elisp.  Like cmacs_dispatch_eval, but when the
   result is a string it is returned verbatim (not prin1-quoted); other
   value types still fall back to the printed representation.  Intended
   for tools that surface raw text such as file contents.  Caller must
   g_free.  On error, set *ERROR and return NULL. */
gchar *cmacs_dispatch_eval_string (const gchar *expression,
                                   GError **error);

/* Open PATH in Emacs via find-file. */
void cmacs_dispatch_find_file (const gchar *path);

/* Display TEXT in the echo area via message. */
void cmacs_dispatch_message (const gchar *text);

/* Require GI namespace NS version VER.  Returns TRUE on success. */
gboolean cmacs_dispatch_gi_require (const gchar *ns, const gchar *ver,
                                    GError **error);

/* Call GI function FUNC in namespace NS with string args.
   Returns printed result (caller must g_free), or NULL on error. */
gchar *cmacs_dispatch_gi_call (const gchar *ns, const gchar *func,
                               const gchar *const *args, gint n_args,
                               GError **error);

/* List functions in GI namespace NS.
   Returns NULL-terminated string array (caller must g_strfreev). */
gchar **cmacs_dispatch_gi_list_functions (const gchar *ns);

/* ── Gowl compositor dispatch (bypasses elisp for performance) ───── */

#ifdef HAVE_CMACS_GOWL

#include <gowl.h>

/* Global compositor instance, defined in cmacs-gowl.c. */
extern GowlCompositor *cmacs_gowl_compositor;

/* List clients as JSON array string. */
gchar *cmacs_dispatch_gowl_list_clients (GError **error);

/* Get focused client info as JSON string. */
gchar *cmacs_dispatch_gowl_focused_client (GError **error);

/* Spawn a command. */
gchar *cmacs_dispatch_gowl_spawn (const gchar *command, GError **error);

/* List monitors as JSON array string. */
gchar *cmacs_dispatch_gowl_list_monitors (GError **error);

/* Add a keybind.  Returns "t" on success. */
gchar *cmacs_dispatch_gowl_add_keybind (const gchar *key, gint action,
                                         const gchar *arg, GError **error);

/* List keybinds as JSON array string. */
gchar *cmacs_dispatch_gowl_list_keybinds (GError **error);

/* Add a window rule. */
gchar *cmacs_dispatch_gowl_add_rule (const gchar *app_id,
                                      const gchar *title,
                                      guint32 tags, gboolean floating,
                                      gint monitor, GError **error);

/* Set layout, mfact, nmaster, view tags. */
gchar *cmacs_dispatch_gowl_set_mfact (gdouble mfact, GError **error);
gchar *cmacs_dispatch_gowl_set_nmaster (gint n, GError **error);
gchar *cmacs_dispatch_gowl_view_tags (guint32 tagmask, GError **error);

/* Session control. */
gchar *cmacs_dispatch_gowl_lock (GError **error);
gchar *cmacs_dispatch_gowl_unlock (GError **error);
gchar *cmacs_dispatch_gowl_reload_config (GError **error);

/* Get config property by name. */
gchar *cmacs_dispatch_gowl_config_get (const gchar *property,
                                        GError **error);

/* Find client by app-id or title pattern. */
gchar *cmacs_dispatch_gowl_find_client (const gchar *pattern,
                                         const gchar *by, GError **error);

/* Monitor info by name (JSON string). */
gchar *cmacs_dispatch_gowl_monitor_info (const gchar *name,
                                          GError **error);

/* Monitor modes by name (JSON array string). */
gchar *cmacs_dispatch_gowl_monitor_modes (const gchar *name,
                                           GError **error);

/* Set monitor mode. */
gchar *cmacs_dispatch_gowl_set_monitor_mode (const gchar *name,
                                              gint w, gint h,
                                              gint refresh_mhz,
                                              GError **error);

/* Monitor position by name (JSON string). */
gchar *cmacs_dispatch_gowl_monitor_position (const gchar *name,
                                              GError **error);

/* Set monitor position. */
gchar *cmacs_dispatch_gowl_set_monitor_pos (const gchar *name,
                                             gint x, gint y,
                                             GError **error);

/* Enable/disable monitor. */
gchar *cmacs_dispatch_gowl_set_monitor_enabled (const gchar *name,
                                                 gboolean en,
                                                 GError **error);

/* Set monitor scale. */
gchar *cmacs_dispatch_gowl_set_monitor_scale (const gchar *name,
                                               gdouble scale,
                                               GError **error);

/* Set monitor transform. */
gchar *cmacs_dispatch_gowl_set_monitor_transform (const gchar *name,
                                                    gint xform,
                                                    GError **error);

#endif /* HAVE_CMACS_GOWL */

#endif /* HAVE_CMACS_GLIB */
#endif /* CMACS_EVAL_DISPATCH_H */
