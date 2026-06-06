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
 * headers).  Cast to LrgRenderer/GPtrArray<LrgDrawable*>/LrgCamera
 * at the scene-builder site (which already includes libregnum.h). */
extern void *cmacs_libregnum_render_ctx_get_renderer (CmacsLibregnumRenderCtx *r);
extern void *cmacs_libregnum_render_ctx_get_scene    (CmacsLibregnumRenderCtx *r);
extern void *cmacs_libregnum_render_ctx_get_camera   (CmacsLibregnumRenderCtx *r);
extern void  cmacs_libregnum_render_ctx_set_camera   (CmacsLibregnumRenderCtx *r,
                                                     void *cam);

/* Scene-builder API: add an LrgDrawable* (e.g. LrgCube3D, LrgSphere3D,
 * LrgText2D wrapped in 3D).  Ownership transfers to the context. */
extern void cmacs_libregnum_render_ctx_add_drawable
                              (CmacsLibregnumRenderCtx *r,
                               void *drawable);
extern void cmacs_libregnum_render_ctx_clear_drawables
                              (CmacsLibregnumRenderCtx *r);

/* ── Scene node model ────────────────────────────────────────────
 * A scene builder records one entry per pickable/labelable node,
 * parallel to the drawables.  Node id == insertion index.  Cleared
 * automatically by clear_drawables. */
extern guint cmacs_libregnum_render_ctx_add_node
                              (CmacsLibregnumRenderCtx *r,
                               const char *path, const char *name,
                               gboolean is_dir, int depth, int parent,
                               float x, float y, float z,
                               float hw, float hh, float hd);
extern guint cmacs_libregnum_render_ctx_node_count
                              (CmacsLibregnumRenderCtx *r);
/* PATH/NAME are borrowed (valid until the next clear/rebuild). */
extern gboolean cmacs_libregnum_render_ctx_node_info
                              (CmacsLibregnumRenderCtx *r, guint id,
                               const char **path, const char **name,
                               gboolean *is_dir, int *depth, int *parent);

/* Selection (highlighted node) + camera focus. */
extern void cmacs_libregnum_render_ctx_set_selected
                              (CmacsLibregnumRenderCtx *r, gint id);
extern gint cmacs_libregnum_render_ctx_get_selected
                              (CmacsLibregnumRenderCtx *r);
extern void cmacs_libregnum_render_ctx_focus_node
                              (CmacsLibregnumRenderCtx *r, gint id);
extern gboolean cmacs_libregnum_render_ctx_focus_active
                              (CmacsLibregnumRenderCtx *r);

/* Ray-pick the nearest node under view-local pixel (VX,VY); -1 miss. */
extern gint cmacs_libregnum_render_ctx_pick
                              (CmacsLibregnumRenderCtx *r,
                               double vx, double vy, int vw, int vh);
/* Project a world point to view-local pixels; FALSE if behind camera. */
extern gboolean cmacs_libregnum_render_ctx_project
                              (CmacsLibregnumRenderCtx *r,
                               float wx, float wy, float wz,
                               int vw, int vh, double *sx, double *sy);
/* Project node ID's label anchor + report NAME/IS_DIR (NAME borrowed).
 * FALSE if out of range or behind the camera. */
extern gboolean cmacs_libregnum_render_ctx_label_at
                              (CmacsLibregnumRenderCtx *r, guint id,
                               int vw, int vh, double *sx, double *sy,
                               const char **name, gboolean *is_dir);

/* Render one frame into DST (BGRA, top-down, w*h*4 bytes).
 * Returns TRUE on success. */
extern gboolean cmacs_libregnum_render_ctx_render_to_bgra
                              (CmacsLibregnumRenderCtx *r,
                               unsigned char *dst, int w, int h);

/* ── Game-module hosting ─────────────────────────────────────────
 * Load a libregnum game packaged as a shared module (.so) into this
 * view and drive it each frame (instead of a static scene). The game
 * renders into the view's FBO via an LrgGameHost backed by this ctx;
 * it has no window of its own and never grabs the real cursor. */
extern gboolean cmacs_libregnum_render_ctx_load_game
                              (CmacsLibregnumRenderCtx *r,
                               const char *so_path, char **error_msg);
extern void cmacs_libregnum_render_ctx_unload_game
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_is_game
                              (CmacsLibregnumRenderCtx *r);

/* Input forwarding into the hosted game (GRL_KEY / mouse-button codes are
 * the graylib enum values; PRESS is non-zero for press, 0 for release). */
extern void cmacs_libregnum_render_ctx_game_key
                              (CmacsLibregnumRenderCtx *r,
                               int grl_key, int press);
extern void cmacs_libregnum_render_ctx_game_mouse_move
                              (CmacsLibregnumRenderCtx *r,
                               double x, double y);
extern void cmacs_libregnum_render_ctx_game_mouse_button
                              (CmacsLibregnumRenderCtx *r,
                               int button, int press);

/* Camera orbit/zoom helpers exposed to input.c so it doesn't have
 * to touch libregnum types directly. */
extern void cmacs_libregnum_render_ctx_orbit_camera
                              (CmacsLibregnumRenderCtx *r,
                               double dx_px, double dy_px);
extern void cmacs_libregnum_render_ctx_zoom_camera
                              (CmacsLibregnumRenderCtx *r,
                               double wheel_dy);
extern void cmacs_libregnum_render_ctx_pan_camera
                              (CmacsLibregnumRenderCtx *r,
                               double dx_px, double dy_px);

/* Camera state serialisation helpers (position, target, fov).
 * Used by the Lisp save/restore path to round-trip the view state
 * through the buffer's YAML.  Coordinates are world-space floats. */
extern void cmacs_libregnum_render_ctx_get_camera_state
                              (CmacsLibregnumRenderCtx *r,
                               double *px, double *py, double *pz,
                               double *tx, double *ty, double *tz,
                               double *fov);
extern void cmacs_libregnum_render_ctx_set_camera_state
                              (CmacsLibregnumRenderCtx *r,
                               double px, double py, double pz,
                               double tx, double ty, double tz,
                               double fov);

#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_RENDER_H */
