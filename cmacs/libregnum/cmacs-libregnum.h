/* cmacs-libregnum.h --- libregnum 3D scene subsystem for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Embeds libregnum scenes inside cmacs buffers.  Each buffer in
 * `cmacs-libregnum-mode' owns a CmacsLibregnumView that drives a
 * libregnum LrgRenderer against a hidden raylib window
 * (FLAG_WINDOW_HIDDEN), rendering into a RenderTexture2D FBO that's
 * pulled back into a BGRA cairo_image_surface and blitted in
 * `pgtk_handle_draw' (same shape that cmacs-video uses).
 *
 * IMPORTANT: This header deliberately does NOT include libregnum.h
 * or raylib.h.  raylib's `Color' struct conflicts with cmacs's
 * pgtkgui.h `Color' typedef, so the raylib/libregnum-touching code
 * is firewalled into cmacs-libregnum-render.c which never sees
 * cmacs internals.  Scene-builder modules that need libregnum
 * types include libregnum.h directly and cast the void* accessors
 * from this header. */

#ifndef CMACS_LIBREGNUM_H
#define CMACS_LIBREGNUM_H

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include <cairo.h>
#include <glib.h>

/* syms_of_cmacs_libregnum / init_cmacs_libregnum are declared in
 * src/lisp.h alongside the other cmacs subsystem entry points. */

/* ── Per-buffer view (cmacs-libregnum-view.c) ───────────────────── */
typedef struct CmacsLibregnumView CmacsLibregnumView;

extern CmacsLibregnumView *cmacs_libregnum_view_new   (Lisp_Object buffer,
                                                       int width, int height);
extern void cmacs_libregnum_view_destroy              (CmacsLibregnumView *v);
extern CmacsLibregnumView *cmacs_libregnum_view_for_buffer (Lisp_Object buffer);
extern Lisp_Object cmacs_libregnum_view_get_buffer    (CmacsLibregnumView *v);
extern void cmacs_libregnum_view_request_redraw       (CmacsLibregnumView *v);

extern cairo_surface_t *cmacs_libregnum_view_lock_surface   (CmacsLibregnumView *v);
extern void             cmacs_libregnum_view_unlock_surface (CmacsLibregnumView *v);

/* ── Animation clock (cmacs-libregnum-view.c) ───────────────────────
 * When a view is `animated', a shared GMainContext timer re-renders it
 * at `cmacs-libregnum-target-fps' for as long as it stays on-screen.
 * Visibility is tracked without Lisp: the overlay paint hook stamps the
 * view each time it blits, and the timer skips views that haven't been
 * painted in the last couple of ticks (i.e. their buffer is hidden). */
extern void cmacs_libregnum_view_set_animated (CmacsLibregnumView *v,
                                               gboolean animated,
                                               int target_fps);
extern gboolean cmacs_libregnum_view_get_animated (CmacsLibregnumView *v);
extern void cmacs_libregnum_view_mark_painted  (CmacsLibregnumView *v);

/* Accessors return void* -- callers that need libregnum types
 * include libregnum.h and cast.  This keeps the header free of
 * the Color typedef conflict. */
extern void *cmacs_libregnum_view_get_renderer_raw (CmacsLibregnumView *v);
extern void *cmacs_libregnum_view_get_scene_raw    (CmacsLibregnumView *v);
extern void *cmacs_libregnum_view_get_camera_raw   (CmacsLibregnumView *v);
extern void  cmacs_libregnum_view_set_camera_raw   (CmacsLibregnumView *v,
                                                    void *cam);

extern void  cmacs_libregnum_view_get_size (CmacsLibregnumView *v,
                                            int *w, int *h);
extern void  cmacs_libregnum_view_resize   (CmacsLibregnumView *v,
                                            int w, int h);

/* Forward-decl of the render context (opaque here). */
typedef struct CmacsLibregnumRenderCtx CmacsLibregnumRenderCtx;
extern CmacsLibregnumRenderCtx *
       cmacs_libregnum_view_get_render_ctx (CmacsLibregnumView *v);

extern void cmacs_libregnum_view_set_payload (CmacsLibregnumView *v,
                                              guint scene_object_id,
                                              Lisp_Object payload);
extern Lisp_Object cmacs_libregnum_view_get_payload (CmacsLibregnumView *v,
                                                     guint scene_object_id);

/* ── Overlay paint hook (cmacs-libregnum-overlay.c) ─────────────── */
struct frame;
extern void cmacs_libregnum_overlay_paint (struct frame *f, cairo_t *cr);

/* ── Input routing (cmacs-libregnum-input.c) ────────────────────── */
extern gboolean cmacs_libregnum_handle_motion (struct frame *f,
                                               double x, double y);
extern gboolean cmacs_libregnum_handle_button (struct frame *f,
                                               int button, int press,
                                               double x, double y);
extern gboolean cmacs_libregnum_handle_scroll (struct frame *f,
                                               double dx, double dy,
                                               double x, double y);

/* ── Registry init (called from init_cmacs_libregnum) ───────────── */
extern void     cmacs_libregnum_view_registry_init    (void);
extern gboolean cmacs_libregnum_view_registry_empty_p (void);

#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_H */
