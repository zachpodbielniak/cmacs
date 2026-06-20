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

#include "lisp.h"
#include <glib.h>
#include <stdint.h>

/* ── Safe Lisp callback invocation from GLib callbacks ────────────────
 *
 * GLib callbacks fire from `g_main_context_dispatch`, which on the pgtk
 * build is driven by `xg_select` (xgselect.c) -- a code path that does
 * NOT pass through `cmacs_glib_dispatch`, so `waiting_for_input` stays
 * true.  Any Lisp signal raised inside such a callback hits
 * `signal_or_quit`'s impossible branch and aborts the whole process
 * before `safe_funcall`'s internal condition-case can catch it.
 *
 * Use these helpers for every safe_calln from a GLib callback.  They
 * temporarily clear `waiting_for_input` around the call so signals
 * stay inside the condition-case.  Always-noop when fn is nil.  */
extern void cmacs_dispatch_safe_callN (Lisp_Object fn, ptrdiff_t nargs,
                                       Lisp_Object *args);
extern void cmacs_dispatch_safe_call1 (Lisp_Object fn, Lisp_Object a1);
extern void cmacs_dispatch_safe_call2 (Lisp_Object fn,
                                       Lisp_Object a1, Lisp_Object a2);
extern void cmacs_dispatch_safe_call3 (Lisp_Object fn,
                                       Lisp_Object a1, Lisp_Object a2,
                                       Lisp_Object a3);

/* ── One-shot callback registry (cookie-keyed, GC-rooted) ─────────────
 *
 * Async jobs (cmacs-piper subprocess, cmacs-whisper worker, etc.) need
 * to stash a Lisp callback through a C heap struct for the duration of
 * a libgio / pthread round-trip.  Holding a raw Lisp_Object in C heap
 * is wrong: it has no GC root, and Emacs may reclaim the closure
 * mid-job.  Instead, register the callback here -- the registry is a
 * staticpro'd Lisp hash table, so the closure stays rooted -- and pass
 * the integer cookie through C.  On completion, invoke1+pop in one
 * call drops the root atomically. */
extern uint64_t   cmacs_dispatch_callback_register (Lisp_Object fn);

/* Look up + remove + invoke under the input guard.  No-ops cleanly if
 * cookie is unknown (e.g. callback was already invoked). */
extern void cmacs_dispatch_callback_invoke1 (uint64_t cookie, Lisp_Object a1);
extern void cmacs_dispatch_callback_invokeN (uint64_t cookie,
                                             ptrdiff_t nargs,
                                             Lisp_Object *args);

/* Drop without invoking (cancellation path). */
extern void cmacs_dispatch_callback_drop    (uint64_t cookie);

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

/* Parse the org-mode buffer BUFFER into a JSON document: buffer-level
   keywords (#+TITLE etc.) plus a nested headline tree (title, level,
   todo, priority, tags, scheduled/deadline/closed, property drawer,
   body text, children).  MATCH is an org agenda match string
   ("work+urgent/TODO" syntax) filtering entries, or NULL/"" for all.
   MAX_DEPTH > 0 limits headline depth.  Returns the JSON string
   (caller g_frees), or NULL with *ERROR set.  Shared by the D-Bus
   Edit.GetOrgContent method and the MCP get_org_content tool so the
   two surfaces stay identical. */
gchar *cmacs_dispatch_org_content (const gchar *buffer,
                                   const gchar *match,
                                   gint         max_depth,
                                   gboolean     include_body,
                                   gboolean     include_properties,
                                   GError     **error);

/* Insert TEXT into the org-mode buffer BUFFER, org-aware.  HEADING
   targets a headline by exact title or by a slash-separated outline
   path ("Projects/cmacs/Log"); empty inserts relative to the whole
   buffer.  CREATE makes missing path components.  POSITION is one of
   "top" (after the entry's meta data), "bottom" (end of the entry's
   own body, before the first child; the default), "subtree-end", or
   "point".  WRAP names an org block ("src" with LANG, "quote",
   "example", "verse", "center", or any custom #+begin_ name); DRAWER
   wraps in a :DRAWER: drawer; CHILD creates a new child headline
   (with optional TODO keyword and colon-separated TAGS) whose body
   is the text; TIMESTAMP prepends an inactive org timestamp.
   Returns a status string (caller g_frees) or NULL with *ERROR.
   Shared by D-Bus Edit.InsertOrg and the MCP insert_org tool. */
gchar *cmacs_dispatch_org_insert (const gchar *buffer,
                                  const gchar *text,
                                  const gchar *heading,
                                  const gchar *position,
                                  const gchar *wrap,
                                  const gchar *lang,
                                  const gchar *drawer,
                                  const gchar *child,
                                  const gchar *todo,
                                  const gchar *tags,
                                  gboolean     create,
                                  gboolean     timestamp,
                                  GError     **error);

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

/* Animated libregnum screensaver wallpaper.  CONFIG is a config name from
 * `cmacs-screensaver-configs' (NULL/"" = the configured/default one). */
gchar *cmacs_dispatch_screensaver_set_wallpaper (const gchar *config,
                                                 GError **error);
gchar *cmacs_dispatch_screensaver_stop_wallpaper (GError **error);
gchar *cmacs_dispatch_screensaver_list_configs (GError **error);
gchar *cmacs_dispatch_screensaver_status (GError **error);
gchar *cmacs_dispatch_screensaver_restart (GError **error);
gchar *cmacs_dispatch_screensaver_pause (GError **error);
gchar *cmacs_dispatch_screensaver_resume (GError **error);
gchar *cmacs_dispatch_screensaver_set_fps (gint fps, GError **error);

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
