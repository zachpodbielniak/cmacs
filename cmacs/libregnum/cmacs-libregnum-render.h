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

/* Process-shared hidden raylib window.  Created on first view creation
 * and then kept resident for the process lifetime: raylib cannot
 * reliably re-create its GL context / FBOs after CloseWindow + a later
 * InitWindow, so release only drops the refcount and never tears the
 * window (or shared engine) down. */
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

/* Render the current frame and write it to PATH as a PNG.  Synchronous
 * (renders + reads back immediately, independent of the animation clock),
 * so it works for headless/automated render verification.  Returns TRUE on
 * success; on failure sets *ERROR_MSG (caller g_free's). */
extern gboolean cmacs_libregnum_render_ctx_snapshot_png
                              (CmacsLibregnumRenderCtx *r,
                               const char *path, char **error_msg);

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

/* ── Editor / level authoring ────────────────────────────────────
 * Drive an engine-side LrgEditor whose level is baked into this view's
 * scene drawables (so it renders through the normal scene path and
 * reuses the node model for picking/labels/outliner).  All parameters
 * are plain C so the Lisp layer needs no libregnum types.  Node ids are
 * the scene-node indices (== cmacs-libregnum-tree-nodes ids). */
extern gboolean cmacs_libregnum_render_ctx_editor_new
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_open
                              (CmacsLibregnumRenderCtx *r,
                               const char *path, char **error_msg);
extern gboolean cmacs_libregnum_render_ctx_editor_save
                              (CmacsLibregnumRenderCtx *r,
                               const char *path, char **error_msg);
extern void     cmacs_libregnum_render_ctx_editor_close
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_active
                              (CmacsLibregnumRenderCtx *r);
/* Add a primitive node (PRIM == LrgPrimitiveType int) and select it.
 * Returns the new node's scene id, or -1 on failure. */
extern gint     cmacs_libregnum_render_ctx_editor_add_primitive
                              (CmacsLibregnumRenderCtx *r,
                               int prim, const char *name);
extern void     cmacs_libregnum_render_ctx_editor_delete
                              (CmacsLibregnumRenderCtx *r, gint node_id);
extern void     cmacs_libregnum_render_ctx_editor_select_node
                              (CmacsLibregnumRenderCtx *r, gint node_id);
extern void     cmacs_libregnum_render_ctx_editor_set_position
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               double x, double y, double z);
extern void     cmacs_libregnum_render_ctx_editor_undo
                              (CmacsLibregnumRenderCtx *r);
extern void     cmacs_libregnum_render_ctx_editor_redo
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_can_undo
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_can_redo
                              (CmacsLibregnumRenderCtx *r);
/* Borrowed guid string for NODE_ID (valid until the next rebuild). */
extern const char *cmacs_libregnum_render_ctx_editor_node_guid
                              (CmacsLibregnumRenderCtx *r, gint node_id);
/* Read NODE_ID's local location.  Returns FALSE if NODE_ID is invalid. */
extern gboolean cmacs_libregnum_render_ctx_editor_node_location
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               double *x, double *y, double *z);
/* Translate grid for drag/move (0 disables); applied to drag end-points. */
extern void     cmacs_libregnum_render_ctx_editor_set_snap
                              (CmacsLibregnumRenderCtx *r, double snap);
/* Mouse drag-to-move on the ground plane.  begin grabs NODE_ID at view-local
 * (VX,VY); update tracks the cursor (live, no undo); end pushes ONE coalesced
 * transform command (one drag == one undo step).  dragging reports state.
 * VW,VH are the viewport pixel size. */
extern gboolean cmacs_libregnum_render_ctx_editor_dragging
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_drag_begin
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               double vx, double vy, int vw, int vh);
extern gboolean cmacs_libregnum_render_ctx_editor_drag_update
                              (CmacsLibregnumRenderCtx *r,
                               double vx, double vy, int vw, int vh);
extern void     cmacs_libregnum_render_ctx_editor_drag_end
                              (CmacsLibregnumRenderCtx *r);
/* Read NODE-ID's rotation (radians) / scale.  FALSE if NODE-ID is invalid. */
extern gboolean cmacs_libregnum_render_ctx_editor_node_rotation
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               double *x, double *y, double *z);
extern gboolean cmacs_libregnum_render_ctx_editor_node_scale
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               double *x, double *y, double *z);
/* Set NODE-ID's rotation (radians) / scale as one undoable transform. */
extern void     cmacs_libregnum_render_ctx_editor_set_rotation
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               double x, double y, double z);
extern void     cmacs_libregnum_render_ctx_editor_set_scale
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               double x, double y, double z);
/* Reparent CHILD-ID under PARENT-ID (PARENT-ID < 0 == level root). */
extern gboolean cmacs_libregnum_render_ctx_editor_reparent
                              (CmacsLibregnumRenderCtx *r,
                               gint child_id, gint parent_id);
/* Add a node of visual KIND (LrgNodeVisualKind int) + optional ASSET path
 * (MESH_ASSET loads + draws the model; SPRITE/LIGHT/CAMERA/AUDIO = gizmos). */
extern gint     cmacs_libregnum_render_ctx_editor_add_visual
                              (CmacsLibregnumRenderCtx *r, int kind,
                               const char *asset, const char *name);
/* Attach a script binding (LANGUAGE = LrgScriptLanguage int) to NODE-ID. */
extern gboolean cmacs_libregnum_render_ctx_editor_attach_script
                              (CmacsLibregnumRenderCtx *r, gint id,
                               int language, const char *path);
extern gint     cmacs_libregnum_render_ctx_editor_node_script_count
                              (CmacsLibregnumRenderCtx *r, gint id);
/* Play-in-editor: instantiate the level into a throwaway world + run it. */
extern gboolean cmacs_libregnum_render_ctx_editor_play
                              (CmacsLibregnumRenderCtx *r);
extern void     cmacs_libregnum_render_ctx_editor_stop
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_playing
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_play_tick
                              (CmacsLibregnumRenderCtx *r, double delta);
/* On-screen transform gizmo.  TOOL: 0 select, 1 translate, 2 rotate, 3 scale.
 * gizmo_hit reports whether a handle is under (VX,VY); begin/drag/end run an
 * axis-constrained transform (one coalesced undo step), like the move drag. */
extern void     cmacs_libregnum_render_ctx_editor_set_tool
                              (CmacsLibregnumRenderCtx *r, int tool);
extern gint     cmacs_libregnum_render_ctx_editor_get_tool
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_gizmo_active
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_gizmo_hit
                              (CmacsLibregnumRenderCtx *r,
                               double vx, double vy, int vw, int vh);
extern gboolean cmacs_libregnum_render_ctx_editor_gizmo_begin
                              (CmacsLibregnumRenderCtx *r,
                               double vx, double vy, int vw, int vh);
extern gboolean cmacs_libregnum_render_ctx_editor_gizmo_drag
                              (CmacsLibregnumRenderCtx *r,
                               double vx, double vy, int vw, int vh);
extern void     cmacs_libregnum_render_ctx_editor_gizmo_end
                              (CmacsLibregnumRenderCtx *r);
/* Top-down orthographic 2D view toggle (for 2D levels). */
extern void     cmacs_libregnum_render_ctx_editor_set_view_2d
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_editor_view_2d
                              (CmacsLibregnumRenderCtx *r);
/* Reflect the running play-world's object positions onto the baked scene. */
extern void     cmacs_libregnum_render_ctx_editor_sync_play
                              (CmacsLibregnumRenderCtx *r);
/* Asset drop-at-point: arm so the next viewport click drops an asset at the
 * ground point under the cursor.  screen_to_ground reports that world point. */
extern void     cmacs_libregnum_render_ctx_editor_set_armed
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_editor_armed
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_editor_screen_to_ground
                              (CmacsLibregnumRenderCtx *r, double vx, double vy,
                               int vw, int vh,
                               double *x, double *y, double *z);
/* Tilemap data (stored in the node's visual params; persists in .rlevel).
 * config sets the tileset image + tile/map dimensions (preserving overlapping
 * cells on resize); set_tile paints one cell; info reports the dimensions. */
extern void     cmacs_libregnum_render_ctx_editor_tilemap_config
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               const char *tileset, int tw, int th, int cols,
                               int mw, int mh);
extern void     cmacs_libregnum_render_ctx_editor_tilemap_set_tile
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               int cx, int cy, int tile);
extern gboolean cmacs_libregnum_render_ctx_editor_tilemap_info
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               int *mw, int *mh, int *cols, int *tw, int *th);

#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_RENDER_H */
