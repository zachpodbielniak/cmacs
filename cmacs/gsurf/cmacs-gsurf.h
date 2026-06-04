/* cmacs-gsurf.h --- CMacs <-> gsurf embedded web browser bridge.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Embeds gsurf (a GLib/GObject port of suckless surf) inside cmacs as a
 * first-class subsystem.  Each `cmacs-gsurf-mode' buffer owns a
 * CmacsGsurfView that wraps a live GsurfView (a WebKitGTK widget),
 * parented into the buffer's pgtk frame and clipped to the buffer's
 * window rectangle (xwidget-style live embed).
 *
 * This header is cmacs-internal and deliberately free of gsurf.h /
 * GTK / WebKit types: the defun layer (cmacs-gsurf-defuns.c) talks to
 * the view through the plain-C helper API below, and only
 * cmacs-gsurf-view.c (the embed translation unit) includes gsurf.h,
 * gtk/gtk.h and pgtkterm.h.  This keeps GTK out of the rest of cmacs
 * (the same firewall shape cmacs-libregnum uses for raylib), and means
 * the defun layer never has to see a GtkWidget. */

#ifndef CMACS_GSURF_H
#define CMACS_GSURF_H

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include <stdbool.h>

/* Opaque per-buffer view handle (defined in cmacs-gsurf-view.c). */
typedef struct CmacsGsurfView CmacsGsurfView;

/* ── Subsystem lifecycle (cmacs-gsurf-init.c) ───────────────────────── */

extern void syms_of_cmacs_gsurf (void);
extern void init_cmacs_gsurf    (void);

/* Lazily bring up the gsurf runtime (gsurf_init + backend_init + the
   process GsurfApplication/GsurfConfig + module-manager search paths +
   GIR typelib path).  Returns true once gsurf is usable.  Safe to call
   repeatedly; the heavy work happens once.  Returns false if gsurf
   could not initialise (e.g. no display / backend init failed). */
extern bool cmacs_gsurf_runtime_ensure (void);

/* True when the gsurf runtime is up and a backend is available. */
extern bool cmacs_gsurf_available_p (void);

/* ── Per-buffer view registry + lifecycle (cmacs-gsurf-view.c) ──────── */

extern CmacsGsurfView *cmacs_gsurf_view_new        (Lisp_Object buffer);
extern void            cmacs_gsurf_view_destroy    (CmacsGsurfView *v);
extern CmacsGsurfView *cmacs_gsurf_view_for_buffer (Lisp_Object buffer);
extern Lisp_Object     cmacs_gsurf_view_buffer     (CmacsGsurfView *v);
/* The native web widget (WebKitWebView*) as void*, for the webkit-only
   translation units (snapshot/print).  NULL if V has no widget. */
extern void           *cmacs_gsurf_view_native_widget (CmacsGsurfView *v);

/* Position the live widget over the pixel rectangle (X, Y, W, H) of the
   buffer's window inside FRAME (a Lisp frame object), and show it.
   Called from the Elisp window-configuration / scroll hooks via
   cmacs-gsurf-place. */
extern void cmacs_gsurf_view_place (CmacsGsurfView *v, Lisp_Object frame,
                                    int x, int y, int w, int h);
/* Hide the live widget (buffer no longer displayed in any window). */
extern void cmacs_gsurf_view_hide  (CmacsGsurfView *v);

/* Make V a headless/offscreen view: host its widget in a
   GtkOffscreenWindow (so WebKit realizes + runs JS) and never parent it
   into a frame.  Used by gsurf-lite, which re-renders the page as Emacs
   text.  cmacs_gsurf_view_place/hide become no-ops for such a view. */
extern void cmacs_gsurf_view_make_offscreen (CmacsGsurfView *v);
extern bool cmacs_gsurf_view_offscreen_p     (CmacsGsurfView *v);

/* Focus handoff: grab GTK keyboard focus to V's web widget (so the page
   receives keys), report whether it currently has focus, or hand focus
   back to the selected frame's edit widget (so Emacs/evil regains
   control).  See cmacs-gsurf-view.c for the model. */
extern void cmacs_gsurf_view_focus_page      (CmacsGsurfView *v);
extern bool cmacs_gsurf_view_page_focused_p  (CmacsGsurfView *v);
extern void cmacs_gsurf_release_focus        (void);
/* Focus the page and pop the modal link-hint overlay (dispatch `f'). */
extern void cmacs_gsurf_view_follow          (CmacsGsurfView *v);

/* True if the per-buffer registry is empty (fast-path bail for hooks). */
extern bool cmacs_gsurf_registry_empty_p (void);

/* Host bridge exported (via temacs --export-dynamic) for the cmacs gsurf
   modules: schedule ELISP (a source string) on the Emacs main thread.
   Defined in cmacs-gsurf-view.c. */
extern void cmacs_gsurf_emacs_eval_async (const char *elisp);

/* Host bridge for the JS->Emacs channel module: deliver a page message
   (raw JSON {channel,payload}) from GSURF_VIEW (a GsurfView*, passed as
   void* to keep this header gsurf-free).  Resolves the originating buffer
   from the registry and routes to the Elisp dispatcher (data only, never
   evaluated).  Defined in cmacs-gsurf-view.c. */
extern void cmacs_gsurf_js_message (void *gsurf_view, const char *message);

/* ── Downloads (cmacs-gsurf-downloads.c) ────────────────────────────── */

/* Wire download tracking onto the process-global default WebKitWebContext
   (idempotent).  Called once from cmacs_gsurf_runtime_ensure after the
   backend is up.  Download lifecycle is delivered to Emacs via the
   `cmacs-gsurf-download-changed-functions' abnormal hook. */
extern void cmacs_gsurf_downloads_init   (void);
/* Cancel the in-flight download with integer ID (no-op if unknown). */
extern void cmacs_gsurf_download_cancel  (unsigned int id);

/* ── Permissions (cmacs-gsurf-permissions.c) ────────────────────────── */

/* Connect the per-view permission-request handler on the native web view
   (WEBVIEW is the GsurfView's native WebKitWebView, passed as void* so this
   header stays WebKit-free).  V is the owning view handle (opaque). */
extern void cmacs_gsurf_permissions_attach (void *webview, CmacsGsurfView *v);
/* Set the policy for ORIGIN ("scheme://host:port") + TYPE
   ("geolocation"/"notification"/"media"/...): ALLOW non-zero = allow. */
extern void cmacs_gsurf_permission_set_policy (const char *origin,
                                               const char *type, int allow);
/* Forget all per-origin permission policies. */
extern void cmacs_gsurf_permission_clear_policies (void);

/* ── Snapshot + print (cmacs-gsurf-snapshot.c / -print.c) ───────────── */

/* Render V to a PNG at PATH (full document when FULL_PAGE, else the
   visible region).  Async; CALLBACK (or nil) is called with the path on
   success or nil on failure. */
extern void cmacs_gsurf_snapshot (CmacsGsurfView *v, const char *path,
                                  Lisp_Object callback, bool full_page);
/* Print V to a PDF at PATH (no dialog).  Async; CALLBACK (or nil) is
   called with the path on success or nil on failure. */
extern void cmacs_gsurf_print_pdf (CmacsGsurfView *v, const char *path,
                                   Lisp_Object callback);

/* ── Navigation / state wrappers (cmacs-gsurf-view.c) ───────────────── */

extern void   cmacs_gsurf_view_load_uri   (CmacsGsurfView *v, const char *uri);
extern void   cmacs_gsurf_view_reload      (CmacsGsurfView *v, bool nocache);
extern void   cmacs_gsurf_view_stop        (CmacsGsurfView *v);
extern void   cmacs_gsurf_view_go_back     (CmacsGsurfView *v);
extern void   cmacs_gsurf_view_go_forward  (CmacsGsurfView *v);
extern bool   cmacs_gsurf_view_can_go_back    (CmacsGsurfView *v);
extern bool   cmacs_gsurf_view_can_go_forward (CmacsGsurfView *v);
/* Returns a freshly g_malloc'd string (caller frees with xfree-safe
   helper that wraps g_free), or NULL. */
extern char  *cmacs_gsurf_view_get_uri     (CmacsGsurfView *v);
extern char  *cmacs_gsurf_view_get_title   (CmacsGsurfView *v);
extern double cmacs_gsurf_view_get_progress (CmacsGsurfView *v);
extern void   cmacs_gsurf_view_set_zoom    (CmacsGsurfView *v, double z);
extern double cmacs_gsurf_view_get_zoom    (CmacsGsurfView *v);
extern void   cmacs_gsurf_view_run_js      (CmacsGsurfView *v, const char *js);
extern void   cmacs_gsurf_view_run_js_cb   (CmacsGsurfView *v, const char *js,
                                            Lisp_Object callback);
extern void   cmacs_gsurf_view_add_user_script (CmacsGsurfView *v,
                                                const char *src, bool at_end);
extern void   cmacs_gsurf_view_find        (CmacsGsurfView *v,
                                            const char *text, bool forward);
extern void   cmacs_gsurf_view_find_next   (CmacsGsurfView *v, bool forward);
/* Free a string returned by the get_* wrappers above. */
extern void   cmacs_gsurf_string_free      (char *s);

/* ── Module manager (cmacs-gsurf-modules.c) ─────────────────────────── */

/* Create the process GsurfConfig (built-in defaults only -- never reads
   gsurf's own user config files) + application, display-free, so Emacs
   can load configuration into it before the modules load.  Idempotent.
   Defined in cmacs-gsurf-init.c. */
extern bool  cmacs_gsurf_config_ensure (void);

/* Configure the module-manager search paths (cmacs custom dir + gsurf
   dev/stock dir + env overrides) and load+activate the modules.  Called
   once from cmacs_gsurf_runtime_ensure after the app/config exist. */
extern void  cmacs_gsurf_modules_init (void);
/* JSON array describing loaded modules: [{"name","description","enabled"}].
   Freshly g_malloc'd; free with cmacs_gsurf_string_free. */
extern char *cmacs_gsurf_modules_list_json (void);
/* Enable/disable a module by name; returns true if the module exists. */
extern bool  cmacs_gsurf_module_set_enabled (const char *name, bool enabled);
/* Re-run configure() on every loaded module (pick up option changes). */
extern void  cmacs_gsurf_modules_reconfigure (void);

/* Load gsurf configuration from Emacs.  None of these are called unless
   Emacs asks (the default config reads no gsurf user files).  Each
   ensures the config exists, loads into it, and reconfigures already-
   loaded modules.  Return true on success; on failure set *ERR_OUT to a
   freshly g_malloc'd message (free with cmacs_gsurf_string_free). */
extern bool  cmacs_gsurf_load_config_data   (const char *yaml, char **err_out);
extern bool  cmacs_gsurf_load_config_file   (const char *path, char **err_out);
extern bool  cmacs_gsurf_load_config_c_file (const char *path, char **err_out);

#endif /* HAVE_CMACS_GSURF */
#endif /* CMACS_GSURF_H */
