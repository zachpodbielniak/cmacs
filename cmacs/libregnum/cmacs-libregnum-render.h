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

/* ── Persistent background model ─────────────────────────────────
 * A single model drawn first every frame, behind the scene drawables,
 * and NOT cleared by clear_drawables.  Used by the gnuseye globe to keep
 * the textured Earth sphere resident across per-tick marker rebuilds.
 * set_background_model takes ownership of MODEL (a GrlModel*, void* to
 * keep this header free of raylib/libregnum types); get returns it borrowed
 * so the builder can update its texture in place. */
extern void  cmacs_libregnum_render_ctx_set_background_model
                              (CmacsLibregnumRenderCtx *r, void *model);
extern void *cmacs_libregnum_render_ctx_get_background_model
                              (CmacsLibregnumRenderCtx *r);
extern void  cmacs_libregnum_render_ctx_set_background_spin
                              (CmacsLibregnumRenderCtx *r, double deg);

/* Radius of an occluding sphere at the origin (the globe), or 0 for none.
 * Labels/billboards behind this sphere's limb are culled so they do not
 * show through from the far side. */
extern void  cmacs_libregnum_render_ctx_set_occluder_radius
                              (CmacsLibregnumRenderCtx *r, double radius);

/* When DIST > 0 the camera orbits an off-origin focus (a selected celestial
 * body): zoom becomes proportional to the camera-to-target distance with
 * floor DIST.  Pass 0 to restore globe-relative zoom. */
extern void  cmacs_libregnum_render_ctx_set_focus_min
                              (CmacsLibregnumRenderCtx *r, double dist);

/* Persistent positioned textured models (gnuseye celestial bodies), keyed
 * by a stable string and drawn right after the background model.  `update'
 * moves an existing body (FALSE if missing); `add' registers/replaces KEY
 * with a GrlModel* (ownership transferred). */
extern gboolean cmacs_libregnum_render_ctx_body_model_update
                              (CmacsLibregnumRenderCtx *r, const gchar *key,
                               double x, double y, double z);
extern void  cmacs_libregnum_render_ctx_body_model_add
                              (CmacsLibregnumRenderCtx *r, const gchar *key,
                               gpointer model, double x, double y, double z);
extern void  cmacs_libregnum_render_ctx_clear_body_models
                              (CmacsLibregnumRenderCtx *r);

/* Persistent static drawables (e.g. a coastline overlay): drawn every frame
 * after the background model, NOT cleared by clear_drawables.  add transfers
 * ownership of DRAWABLE (an LrgDrawable*, void* to keep the header clean). */
extern void  cmacs_libregnum_render_ctx_add_static_drawable
                              (CmacsLibregnumRenderCtx *r, void *drawable);
extern void  cmacs_libregnum_render_ctx_clear_static_drawables
                              (CmacsLibregnumRenderCtx *r);

/* ── Filled polygon models ───────────────────────────────────────
 * Translucent triangulated meshes (a GrlModel*, void* to keep this header
 * free of raylib/libregnum types) draped on the globe surface: weather
 * alert zones, choropleth country fills, aurora ovals, AOIs.  Drawn after
 * the background model and BEFORE static drawables/markers, alpha-blended
 * and two-sided (backface cull disabled) so the translucent surface shows
 * from any angle and the coastlines/markers overlay it.  Two lists:
 * `polygon' is per-tick (cleared with the markers); `static_polygon' is
 * persistent (cleared only explicitly, like the coastline overlay).
 * add takes ownership of MODEL. */
extern void  cmacs_libregnum_render_ctx_add_polygon_model
                              (CmacsLibregnumRenderCtx *r, void *model);
extern void  cmacs_libregnum_render_ctx_clear_polygon_models
                              (CmacsLibregnumRenderCtx *r);
extern void  cmacs_libregnum_render_ctx_add_static_polygon_model
                              (CmacsLibregnumRenderCtx *r, void *model);
extern void  cmacs_libregnum_render_ctx_clear_static_polygon_models
                              (CmacsLibregnumRenderCtx *r);

/* ── Map labels ──────────────────────────────────────────────────
 * Persistent text labels at fixed world points (country/region names),
 * projected + drawn by the overlay.  Survive marker rebuilds. */
extern void  cmacs_libregnum_render_ctx_add_map_label
                              (CmacsLibregnumRenderCtx *r,
                               float x, float y, float z, const char *text,
                               guint8 cr, guint8 cg, guint8 cb);
extern void  cmacs_libregnum_render_ctx_clear_map_labels
                              (CmacsLibregnumRenderCtx *r);
extern guint cmacs_libregnum_render_ctx_map_label_count
                              (CmacsLibregnumRenderCtx *r);
extern gboolean cmacs_libregnum_render_ctx_map_label_at
                              (CmacsLibregnumRenderCtx *r, guint id,
                               int vw, int vh, double *sx, double *sy,
                               const char **text,
                               guint8 *cr, guint8 *cg, guint8 *cb);
extern double cmacs_libregnum_render_ctx_camera_distance
                              (CmacsLibregnumRenderCtx *r);

/* ── Billboards ──────────────────────────────────────────────────
 * Camera-facing textured quads (e.g. country flags) at fixed world points.
 * add takes ownership of TEXTURE (a GrlTexture*, void* to keep the header
 * clean).  Drawn each frame; the caller's render path may gate by zoom. */
extern void  cmacs_libregnum_render_ctx_add_billboard
                              (CmacsLibregnumRenderCtx *r,
                               float x, float y, float z,
                               void *texture, float size);
extern void  cmacs_libregnum_render_ctx_clear_billboards
                              (CmacsLibregnumRenderCtx *r);
extern guint cmacs_libregnum_render_ctx_billboard_count
                              (CmacsLibregnumRenderCtx *r);

/* ── Per-node label policy ───────────────────────────────────────
 * Generalises the overlay's label filter.  LEGACY (-1) keeps the original
 * behaviour (label directories + the selected node); the others let a
 * scene builder pick per node.  HOVER labels the node under the cursor
 * (set via set_hovered) plus the selection. */
typedef enum
{
  CMACS_LIBREGNUM_LABEL_LEGACY   = -1,
  CMACS_LIBREGNUM_LABEL_NEVER    = 0,
  CMACS_LIBREGNUM_LABEL_SELECTED = 1,
  CMACS_LIBREGNUM_LABEL_HOVER    = 2,
  CMACS_LIBREGNUM_LABEL_ALWAYS   = 3
} CmacsLibregnumLabelMode;

extern void cmacs_libregnum_render_ctx_set_node_label_mode
                              (CmacsLibregnumRenderCtx *r, gint id, int mode);
extern int  cmacs_libregnum_render_ctx_get_node_label_mode
                              (CmacsLibregnumRenderCtx *r, gint id);
extern void cmacs_libregnum_render_ctx_set_hovered
                              (CmacsLibregnumRenderCtx *r, gint id);
extern gint cmacs_libregnum_render_ctx_get_hovered
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

/* Render the scene INTO the FBO without a CPU readback (the lrg backend
 * blits the FBO texture directly).  Must be called with the GL context
 * current -- e.g. from inside the lrg present. */
extern gboolean cmacs_libregnum_render_ctx_render_into_fbo
                              (CmacsLibregnumRenderCtx *r);

/* Borrowed (non-owning) GrlTexture* for the FBO colour attachment, as an
 * opaque gpointer so this header stays raylib/graylib-free.  Valid until the
 * ctx is resized or freed.  NULL if the FBO is invalid. */
extern gpointer cmacs_libregnum_render_ctx_get_fbo_texture
                              (CmacsLibregnumRenderCtx *r);

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
/* Full-focus mouse capture: TRUE = view grabs all frame clicks while focused
 * (game); FALSE (default) = only clicks inside its own window (editor). */
extern gboolean cmacs_libregnum_render_ctx_get_mouse_capture_all
                              (CmacsLibregnumRenderCtx *r);
extern void     cmacs_libregnum_render_ctx_set_mouse_capture_all
                              (CmacsLibregnumRenderCtx *r, gboolean capture);

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
extern void     cmacs_libregnum_render_ctx_editor_refresh
                  (CmacsLibregnumRenderCtx *ctx);
#ifdef HAVE_CMACS_CAD
/* CMACS CAD: drop the CAD manager's caches for PATH (next rebuild
 * re-evaluates the part). */
extern void     cmacs_libregnum_render_cad_invalidate (const char *path);
extern gboolean cmacs_libregnum_render_cad_set_source (const char *path,
                                                       const char *source,
                                                       GError **error);
#endif
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
/* Return node ID's live engine object as a borrowed GObject* (cast to void*),
 * for the introspection-driven inspector; NULL if absent. */
extern void *   cmacs_libregnum_render_ctx_editor_node_object
                              (CmacsLibregnumRenderCtx *r, gint node_id);
/* Prefabs: save a node subtree to PATH; instantiate a .rprefab under PARENT_ID
 * (-1 = root), returning the new node id (or -1). */
extern gboolean cmacs_libregnum_render_ctx_editor_save_prefab
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               const char *path);
extern gint     cmacs_libregnum_render_ctx_editor_instantiate_prefab
                              (CmacsLibregnumRenderCtx *r, const char *path,
                               gint parent_id);
/* Import a Blender-exported scene YAML as the editor's current level. */
extern gboolean cmacs_libregnum_render_ctx_editor_import_scene
                              (CmacsLibregnumRenderCtx *r, const char *path);
/* Available scripting backends (singleton manager; index 0..count-1). */
extern gint     cmacs_libregnum_scripting_language_count (void);
extern gint     cmacs_libregnum_scripting_language_at    (gint index);
extern char *   cmacs_libregnum_scripting_language_name  (gint index);
/* Project: create a manifest under ROOT; open ROOT + load its default level. */
extern gboolean cmacs_libregnum_project_create (const char *root,
                               const char *name, const char *default_level,
                               const char *game_output);
extern gboolean cmacs_libregnum_render_ctx_editor_open_project
                              (CmacsLibregnumRenderCtx *r, const char *root);
/* Asset database: scan DIR (opaque handle), enumerate, free.  FIELD: 0 path,
 * 1 name, 2 guid.  type is an LrgAssetType int. */
extern void *   cmacs_libregnum_assetdb_scan       (const char *dir);
extern gint     cmacs_libregnum_assetdb_count      (void *db);
extern char *   cmacs_libregnum_assetdb_entry      (void *db, gint index,
                                                    gint field);
extern gint     cmacs_libregnum_assetdb_entry_type (void *db, gint index);
extern void     cmacs_libregnum_assetdb_free       (void *db);
/* Set a numeric visual param on a node (light range/r/g/b, camera fov, audio
 * range) so the editor's light/camera/audio gizmos reflect authored values. */
extern void     cmacs_libregnum_render_ctx_editor_set_visual_param
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               const char *name, double value);
/* Same, but as an UNDOABLE editor command; MERGE coalesces a continuing
 * slider drag onto the previous command (one undo step for the drag). */
extern gboolean cmacs_libregnum_render_ctx_editor_set_visual_param_undoable
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               const char *name, double value,
                               gboolean merge);
/* Node's visual asset path (sound/mesh/sprite/tileset), newly-allocated. */
extern char *   cmacs_libregnum_render_ctx_editor_node_asset
                              (CmacsLibregnumRenderCtx *r, gint node_id);
/* Node's visual kind (LrgNodeVisualKind int), or -1 if it has no visual (a
 * group node) or the id is unknown.  Drives the per-kind right-click menu. */
extern gint     cmacs_libregnum_render_ctx_editor_node_kind
                              (CmacsLibregnumRenderCtx *r, gint node_id);
/* Node's LrgPrimitiveType int when it is a primitive, else -1 (used for the
 * outliner's concrete-shape type label). */
extern gint     cmacs_libregnum_render_ctx_editor_node_primitive
                              (CmacsLibregnumRenderCtx *r, gint node_id);
/* Rename node ID and re-bake so cached labels (outliner) refresh. */
extern void     cmacs_libregnum_render_ctx_editor_set_name
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               const char *name);

/* Material / color authoring (floats 0..1).  Returns FALSE if the node or
 * its visual is absent.  set_color creates a material when one is missing. */
extern gboolean cmacs_libregnum_render_ctx_editor_set_color
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               float fr, float fg, float fb, float fa);
extern gboolean cmacs_libregnum_render_ctx_editor_node_color
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               float *fr, float *fg,
                               float *fb, float *fa);
extern gboolean cmacs_libregnum_render_ctx_editor_set_roughness
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               float v);
extern gboolean cmacs_libregnum_render_ctx_editor_set_metallic
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               float v);

/* Clone / hierarchy. */
extern gint     cmacs_libregnum_render_ctx_editor_duplicate_node
                              (CmacsLibregnumRenderCtx *r, gint node_id);
extern gint     cmacs_libregnum_render_ctx_editor_node_parent
                              (CmacsLibregnumRenderCtx *r, gint node_id);
extern gint     cmacs_libregnum_render_ctx_editor_add_empty
                              (CmacsLibregnumRenderCtx *r, const char *name,
                               gint parent_id);

/* Scripts: node_scripts returns a borrowed GPtrArray of LrgScriptBinding*;
 * detach_script removes the INDEXth binding (0-based). */
extern GPtrArray *cmacs_libregnum_render_ctx_editor_node_scripts
                              (CmacsLibregnumRenderCtx *r, gint node_id);
extern gboolean cmacs_libregnum_render_ctx_editor_detach_script
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               gint index);

/* Asset: set the visual asset path on NODE_ID. */
extern gboolean cmacs_libregnum_render_ctx_editor_set_node_asset
                              (CmacsLibregnumRenderCtx *r, gint node_id,
                               const char *asset);

/* Unpack prefab: strip the visual (leaves a group). */
extern gboolean cmacs_libregnum_render_ctx_editor_unpack_prefab
                              (CmacsLibregnumRenderCtx *r, gint node_id);

/* Multi-select: additive add/remove/clear; selected_ids returns a
 * transfer-full GArray of gint that the caller g_array_unref()s. */
extern gboolean cmacs_libregnum_render_ctx_editor_select_add
                              (CmacsLibregnumRenderCtx *r, gint node_id);
extern gboolean cmacs_libregnum_render_ctx_editor_select_remove
                              (CmacsLibregnumRenderCtx *r, gint node_id);
extern void     cmacs_libregnum_render_ctx_editor_select_clear
                              (CmacsLibregnumRenderCtx *r);
extern GArray  *cmacs_libregnum_render_ctx_editor_selected_ids
                              (CmacsLibregnumRenderCtx *r);

/* Render features: shading, look-through camera, visual param read-back. */

/* Feature 1: real-time Blinn-Phong scene shading.
 * set_shading enables/disables lit rendering; shading_p queries the state. */
extern void     cmacs_libregnum_render_ctx_editor_set_shading
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_editor_shading_p
                              (CmacsLibregnumRenderCtx *r);
/* Camera-anchored key+fill rig (lights a model-only scene) + a dark edge
 * overlay (shaded-with-edges).  Both need shading on to take effect. */
extern void     cmacs_libregnum_render_ctx_editor_set_headlight
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern void     cmacs_libregnum_render_ctx_editor_set_edges
                              (CmacsLibregnumRenderCtx *r, gboolean on);

/* Feature 2: look-through camera.
 * look_through drives the viewport from CAMERA node ID (returns FALSE if not
 * a CAMERA node); look_through_off restores orbit; look_through_p returns
 * the active node id or -1. */
extern gboolean cmacs_libregnum_render_ctx_editor_look_through
                              (CmacsLibregnumRenderCtx *r, gint id);
extern void     cmacs_libregnum_render_ctx_editor_look_through_off
                              (CmacsLibregnumRenderCtx *r);
extern gint     cmacs_libregnum_render_ctx_editor_look_through_p
                              (CmacsLibregnumRenderCtx *r);

/* Feature 3: per-node visual param read-back.
 * Returns the named param for node ID as a double, or DEF on any error. */
extern double   cmacs_libregnum_render_ctx_editor_get_visual_param
                              (CmacsLibregnumRenderCtx *r, gint id,
                               const char *name, double def);

#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_RENDER_H */
