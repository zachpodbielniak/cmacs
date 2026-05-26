/* cmacs-libregnum-render.h --- C-only render-helper API.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Plain-C API exposed by cmacs-libregnum-render.c.  Designed to
 * NOT pull in raylib/libregnum types so cmacs-internal headers
 * (which define a conflicting `Color' typedef) can include this
 * freely. */

#ifndef CMACS_LIBREGNUM_RENDER_H
#define CMACS_LIBREGNUM_RENDER_H

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include <glib.h>

/* Process-shared hidden raylib window.  Refcounted -- acquire on
 * first view creation, release on last view destruction. */
extern gboolean cmacs_libregnum_render_window_acquire (gchar **error_msg);
extern void     cmacs_libregnum_render_window_release (void);

/* Per-view render context (opaque -- pointers to libregnum/raylib
 * types stay private to render.c). */
typedef struct CmacsLibregnumRenderCtx CmacsLibregnumRenderCtx;

extern CmacsLibregnumRenderCtx *cmacs_libregnum_render_ctx_new
                                            (int w, int h);
extern void cmacs_libregnum_render_ctx_free  (CmacsLibregnumRenderCtx *r);
extern void cmacs_libregnum_render_ctx_resize (CmacsLibregnumRenderCtx *r,
                                               int w, int h);

/* Borrowed pointers (typed as void* so callers don't need libregnum
 * headers).  Cast to LrgRenderer/LrgSceneEntity/LrgCamera at the
 * scene-builder site (which already includes libregnum.h). */
extern void *cmacs_libregnum_render_ctx_get_renderer (CmacsLibregnumRenderCtx *r);
extern void *cmacs_libregnum_render_ctx_get_scene    (CmacsLibregnumRenderCtx *r);
extern void *cmacs_libregnum_render_ctx_get_camera   (CmacsLibregnumRenderCtx *r);
extern void  cmacs_libregnum_render_ctx_set_camera   (CmacsLibregnumRenderCtx *r,
                                                     void *cam);

/* Render one frame into DST (BGRA, top-down, w*h*4 bytes).
 * Returns TRUE on success. */
extern gboolean cmacs_libregnum_render_ctx_render_to_bgra
                              (CmacsLibregnumRenderCtx *r,
                               unsigned char *dst, int w, int h);

/* Camera orbit/zoom helpers exposed to input.c so it doesn't have
 * to touch libregnum types directly. */
extern void cmacs_libregnum_render_ctx_orbit_camera
                              (CmacsLibregnumRenderCtx *r,
                               double dx_px, double dy_px);
extern void cmacs_libregnum_render_ctx_zoom_camera
                              (CmacsLibregnumRenderCtx *r,
                               double wheel_dy);

#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_RENDER_H */
