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

/* ── Translucent overlay shells ───────────────────────────────────
 * Keyed alpha-blended models draped concentrically over the background
 * globe (gnuseye weather: radar, clouds).  Drawn after the background +
 * body models and BEFORE the polygon models, sorted ascending by
 * SORT_KEY (shell radius) so higher shells composite over lower, with
 * depth WRITES disabled -- later passes (alert zones, coastlines,
 * markers, labels) depth-test against the base globe only and always
 * read on top.  They rotate with the background spin so a draped
 * texture stays glued to the globe's geography.  `set' takes ownership
 * of MODEL (a GrlModel*, void* to keep this header raylib-free); NULL
 * removes KEY.  `get' returns the model borrowed. */
extern void  cmacs_libregnum_render_ctx_overlay_model_set
                              (CmacsLibregnumRenderCtx *r, const gchar *key,
                               gpointer model, double sort_key);
extern gpointer cmacs_libregnum_render_ctx_overlay_model_get
                              (CmacsLibregnumRenderCtx *r, const gchar *key);
extern void  cmacs_libregnum_render_ctx_overlay_set_alpha
                              (CmacsLibregnumRenderCtx *r, const gchar *key,
                               double alpha);
extern void  cmacs_libregnum_render_ctx_overlay_set_enabled
                              (CmacsLibregnumRenderCtx *r, const gchar *key,
                               gboolean enabled);
extern void  cmacs_libregnum_render_ctx_clear_overlay_models
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
/* As add_billboard, but tinted and addressable: returns an index usable
 * with move_billboard / set_billboard_color until the next clear.
 *
 * Both exist because a billboard that cannot move is only good for
 * something nailed to the world (a flag on a globe).  A scene whose
 * nodes tween, drag or rotate needs to carry its billboards along, and
 * without a tint every node would need its own copy of what is
 * otherwise one shared texture. */
extern gint  cmacs_libregnum_render_ctx_add_billboard_full
                              (CmacsLibregnumRenderCtx *r,
                               float x, float y, float z,
                               void *texture, float size, guint32 rgba);
extern void  cmacs_libregnum_render_ctx_move_billboard
                              (CmacsLibregnumRenderCtx *r, gint idx,
                               float x, float y, float z);
extern void  cmacs_libregnum_render_ctx_set_billboard_color
                              (CmacsLibregnumRenderCtx *r, gint idx,
                               guint32 rgba);
extern void  cmacs_libregnum_render_ctx_set_billboard_size
                              (CmacsLibregnumRenderCtx *r, gint idx,
                               float size);

/* A soft additive glow at (X, Y, Z): a camera-facing quad carrying a
 * shared radial-falloff texture, drawn AFTER the normal billboards with
 * additive blending and the depth mask off.
 *
 * Additive is what makes it a glow rather than a smudge: it can only
 * brighten what is under it, overlapping glows sum instead of
 * occluding, and draw order stops mattering entirely -- which is why
 * this layer needs no sorting.  The depth mask stays off for the same
 * reason as particles: a translucent quad that writes depth punches an
 * invisible hole other glows behind it cannot draw through.  Depth
 * TESTING stays on, so a glow behind real geometry is still hidden.
 *
 * RGBA tints the shared texture; the alpha channel scales intensity.
 * Returns an index in the same space as add_billboard_full, usable with
 * move_billboard / set_billboard_color / set_billboard_size until the
 * next clear, or -1 on failure. */
extern gint  cmacs_libregnum_render_ctx_add_billboard_glow
                              (CmacsLibregnumRenderCtx *r,
                               float x, float y, float z,
                               float size, guint32 rgba);

/* A shared, lazily built texture of a lit sphere: ambient + diffuse +
 * a tight specular + a rim term, with a soft circular alpha mask.
 *
 * This is how a node gets to look like a ball.  raylib draws an unlit
 * sphere in one flat colour, and the renderer's real lighting applies
 * only to MESH_ASSET models inside the editor build -- so a graph of a
 * few thousand spheres has no shading available to it at all.  A
 * camera-facing quad carrying a pre-lit sphere is the standard answer
 * (an impostor), and unlike a highlight offset in world space it is
 * correct from every camera angle rather than from one.
 *
 * Mip-mapped, because these are drawn at a few pixels across and
 * minifying a sharp texture without mipmaps shimmers on every camera
 * move.  Borrowed: the context owns it. */
extern void *cmacs_libregnum_render_ctx_orb_texture
                              (CmacsLibregnumRenderCtx *r);
extern void  cmacs_libregnum_render_ctx_clear_billboards
                              (CmacsLibregnumRenderCtx *r);
extern guint cmacs_libregnum_render_ctx_billboard_count
                              (CmacsLibregnumRenderCtx *r);

/* ── Shaded orbs: real, lit sphere GEOMETRY ───────────────────────
 *
 * The impostor above is a flat quad wearing a picture of a sphere, and
 * that is exactly what it eventually looks like: its highlight is baked
 * into screen space, so orbiting the scene never changes how any node is
 * lit and the map reads as a sheet of stickers.  These are real
 * spheres -- correct silhouettes, correct occlusion, correct depth --
 * shaded per vertex so they are round rather than the flat discs
 * raylib's own DrawSphere produces (it draws unlit, in one colour, and
 * this renderer's real lighting reaches only MESH_ASSET models inside
 * the editor build).
 *
 * Lighting is a world-fixed KEY plus a camera-following FILL, and having
 * both is the point.  A pure headlight looks like the answer and is the
 * trap: a sphere lit from wherever you happen to be standing looks
 * exactly the same from every angle, so the geometry would be real and
 * the picture would still read as a sheet of stickers.  A pure key light
 * is the opposite trap -- half the graph turns to silhouette as you
 * orbit, and in a map whose colours ARE the taxonomy an unidentifiable
 * node is a lost node.  Key for form, fill for legibility.
 *
 * Cost is vertices, so LOD is per orb and chosen by the caller from how
 * big the thing actually is: a department hub is worth triangles, a leaf
 * a few pixels across is not.  Normals do not vary between orbs -- every
 * one is the same unit sphere -- so the per-vertex lighting term is
 * computed ONCE PER FRAME per LOD and reused by every orb at that LOD.
 * That is what keeps thousands of lit spheres affordable.
 *
 * Indices are their own space (not the billboards'), valid until the
 * next clear_orbs. */
typedef enum
{
  CMACS_LIBREGNUM_ORB_LOD_LOW = 0,   /* 5x8   -- leaves in a crowd */
  CMACS_LIBREGNUM_ORB_LOD_MED,       /* 6x10  -- ordinary nodes */
  CMACS_LIBREGNUM_ORB_LOD_HIGH,      /* 12x20 -- landmarks */
  CMACS_LIBREGNUM_ORB_LOD_COUNT
} CmacsLibregnumOrbLod;

extern gint  cmacs_libregnum_render_ctx_add_orb
                              (CmacsLibregnumRenderCtx *r,
                               float x, float y, float z, float radius,
                               guint32 rgba, int lod);
extern void  cmacs_libregnum_render_ctx_move_orb
                              (CmacsLibregnumRenderCtx *r, gint idx,
                               float x, float y, float z);
extern void  cmacs_libregnum_render_ctx_set_orb_color
                              (CmacsLibregnumRenderCtx *r, gint idx,
                               guint32 rgba);
extern void  cmacs_libregnum_render_ctx_set_orb_radius
                              (CmacsLibregnumRenderCtx *r, gint idx,
                               float radius);
extern void  cmacs_libregnum_render_ctx_clear_orbs
                              (CmacsLibregnumRenderCtx *r);
extern guint cmacs_libregnum_render_ctx_orb_count
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

/* Single source of truth for the per-node label policy above, shared by
 * the in-scene pass and the legacy cairo overlay so they cannot
 * disagree. */
extern gboolean cmacs_libregnum_render_ctx_label_visible_p
                              (CmacsLibregnumRenderCtx *r, guint id);

/* ── In-scene labels ─────────────────────────────────────────────
 * Node labels are drawn by default in cmacs-libregnum-overlay.c, in
 * cairo, from pgtk_handle_draw -- which means they do not exist under
 * `emacs --lrg', and never appear in a snapshot_png.  Turning this on
 * moves them INTO the FBO, drawn as a screen-space pass at the end of
 * render_to_bgra: both backends funnel through that function, so one
 * code path serves both and the result is testable.
 *
 * The cairo pass suppresses itself when this is on, so nothing is
 * double-drawn under pgtk.  Contexts that never call this keep the
 * legacy behaviour byte for byte. */
extern void     cmacs_libregnum_render_ctx_set_inscene_labels
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_inscene_labels_p
                              (CmacsLibregnumRenderCtx *r);

/* Suppress orbiting; pan and zoom keep working.  For a scene whose
 * content is planar and viewed head-on there is nothing to orbit
 * around, and tumbling it only reveals that everything is coplanar. */
extern void     cmacs_libregnum_render_ctx_set_orbit_locked
                              (CmacsLibregnumRenderCtx *r, gboolean locked);
extern gboolean cmacs_libregnum_render_ctx_orbit_locked_p
                              (CmacsLibregnumRenderCtx *r);

/* Let the orbit tumble all the way over the poles instead of stopping
 * just short of them.
 *
 * The default (FALSE) clamps the elevation to about +/- 80 degrees,
 * which is right for a scene with a canonical up: on a globe north stays
 * up and the view never goes upside down.  It is wrong for a scene with
 * no canonical up -- a graph, a warped disc -- where the clamp reads as
 * the drag simply stopping in one direction, for no reason the picture
 * explains.
 *
 * With this on the elevation runs continuously through a full turn and
 * the camera's UP VECTOR flips as it crosses a pole, which is what keeps
 * the image continuous instead of snapping through a gimbal.  Horizontal
 * drag is negated while inverted, so dragging right still turns the
 * scene the way it moves on screen. */
extern void     cmacs_libregnum_render_ctx_set_orbit_continuous
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_orbit_continuous_p
                              (CmacsLibregnumRenderCtx *r);

/* What a right-drag does.  The default (FALSE) is the CAD profile:
 * either button orbits, the middle one pans.  TRUE makes right-drag pan
 * instead, which is what a map-like scene wants -- and what a user with
 * no middle button can actually reach.  A right-click without movement
 * still opens the context menu either way. */
extern void     cmacs_libregnum_render_ctx_set_right_drag_pans
                              (CmacsLibregnumRenderCtx *r, gboolean pans);
extern gboolean cmacs_libregnum_render_ctx_right_drag_pans_p
                              (CmacsLibregnumRenderCtx *r);

/* Which way the wheel zooms.  GDK reports a positive delta for scrolling
 * DOWN and the zoom kernel moves closer for a positive amount, so the
 * inherited behaviour is "scroll down to move closer" -- the opposite of
 * every map, browser and 3-D viewer.  TRUE selects the conventional
 * direction (wheel up moves closer).  Default FALSE, so scenes that
 * shipped with the old direction keep it until they opt in. */
extern void     cmacs_libregnum_render_ctx_set_wheel_up_zooms_in
                              (CmacsLibregnumRenderCtx *r,
                               gboolean up_zooms_in);
extern gboolean cmacs_libregnum_render_ctx_wheel_up_zooms_in_p
                              (CmacsLibregnumRenderCtx *r);

/* Current framebuffer size; scene builders need the aspect to frame
 * their content. */
extern void cmacs_libregnum_render_ctx_get_size
                              (CmacsLibregnumRenderCtx *r, int *w, int *h);

/* Load a TTF for label text.  Without one, labels fall back to raylib's
 * built-in 10px bitmap font, which is ragged at any other size.  Bake
 * BASE_PX large (32 is a good default) and draw smaller: downscaling
 * through the bilinear filter is what makes it look right, and it makes
 * the draw size a free runtime knob.  BASE_PX <= 0 uses the loader's
 * default size. */
extern void cmacs_libregnum_render_ctx_set_label_font
                              (CmacsLibregnumRenderCtx *r,
                               const char *ttf_path, int base_px);

/* PX is the draw height (0 = built-in default), SHADOW draws a 1px
 * offset drop shadow, DECLUTTER drops labels that would overlap one
 * already placed (selection and hover are exempt), and MAX_LABELS caps
 * how many are drawn per frame (0 = built-in default). */
extern void cmacs_libregnum_render_ctx_set_label_style
                              (CmacsLibregnumRenderCtx *r, int px,
                               gboolean shadow, gboolean declutter,
                               int max_labels);

/* BACKDROP draws a translucent plate behind each label -- over a dense
 * scene the geometry runs straight through the text otherwise.  RINGS
 * draws screen-space emphasis rings on the selected, hovered and
 * matched nodes; being screen-space, they read the same at any zoom,
 * which a fixed world-space marker does not.  Both off by default. */
extern void cmacs_libregnum_render_ctx_set_label_decor
                              (CmacsLibregnumRenderCtx *r,
                               gboolean backdrop, gboolean rings);

/* How the selected node is marked in the 3D pass.  The legacy wireframe
 * box suits scenes whose nodes are boxes (the file tree, the editor); a
 * scene made of spheres wants HALO, and one drawing its own
 * screen-space rings wants NONE. */
typedef enum
{
  CMACS_LIBREGNUM_SELECTION_BOX  = 0,   /* legacy default */
  CMACS_LIBREGNUM_SELECTION_NONE = 1,
  CMACS_LIBREGNUM_SELECTION_HALO = 2
} CmacsLibregnumSelectionStyle;

extern void cmacs_libregnum_render_ctx_set_selection_style
                              (CmacsLibregnumRenderCtx *r, int style);

/* ── Per-node flags ──────────────────────────────────────────────
 * A bitmask that coexists with the single `selected' index rather than
 * competing with it: a search match set and a selection are different
 * things and must both be expressible at once.  MATCH and DIM together
 * give the "highlight these, fade the rest" reading that makes a search
 * legible on a crowded graph. */
typedef enum
{
  CMACS_LIBREGNUM_NODE_MATCH     = 1u << 0,  /* a search hit */
  CMACS_LIBREGNUM_NODE_DIM       = 1u << 1,  /* de-emphasised */
  CMACS_LIBREGNUM_NODE_PINNED    = 1u << 2,  /* user pinned */
  CMACS_LIBREGNUM_NODE_NEIGHBOUR = 1u << 3   /* one hop from the selection */
} CmacsLibregnumNodeFlags;

extern void  cmacs_libregnum_render_ctx_set_node_flags
                              (CmacsLibregnumRenderCtx *r, gint id,
                               guint flags);
extern guint cmacs_libregnum_render_ctx_get_node_flags
                              (CmacsLibregnumRenderCtx *r, gint id);
extern void  cmacs_libregnum_render_ctx_clear_node_flags
                              (CmacsLibregnumRenderCtx *r, guint mask);

/* Bulk update: clear MATCH everywhere, set it on IDS, and set DIM on
 * everything else when DIM_REST.  One call per keystroke rather than
 * one per node, which is the difference between a usable incremental
 * search and an unusable one. */
extern void  cmacs_libregnum_render_ctx_set_match_set
                              (CmacsLibregnumRenderCtx *r,
                               const gint *ids, gsize n,
                               gboolean dim_rest);

/* ── Node dragging (non-editor scenes) ───────────────────────────
 *
 * Off by default.  Dragging used to be reachable only through the
 * editor, whose drag path also selects into the editor's own model and
 * builds undo entries -- neither of which a graph view wants.  With this
 * on, a left-press on a node starts a drag, motion reports the world
 * point under the cursor to Lisp, and the scene decides what that means.
 *
 * The scene decides, and not this layer, because the position that
 * matters lives in the graph: moving only the drawable would look right
 * until the next layout pass silently put it back. */
extern void     cmacs_libregnum_render_ctx_set_drag_nodes
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_drag_nodes (CmacsLibregnumRenderCtx *r);

/* ── Focus policy ────────────────────────────────────────────────
 * How the camera responds to picking.
 *
 * ON_CLICK (default TRUE, the historical behaviour) flies the camera to
 * whatever a left click hits.  That suits a scene you navigate BY
 * clicking -- the project tree, the globe -- and is wrong for one you
 * navigate by looking at, where it snatches the view away from the
 * thing the click just started.
 *
 * CONTEXT_FRAC (default 0, off) puts a floor under the focus distance
 * at that fraction of the whole scene's extent.  Without it the
 * distance is derived from the NODE's own size, which says nothing
 * about the scale of the scene around it: a 0.2-unit sphere in a
 * 70-unit graph gets framed from 6 units away, filling the view with
 * one dot and none of its surroundings. */
extern void cmacs_libregnum_render_ctx_set_focus_policy
                              (CmacsLibregnumRenderCtx *r,
                               gboolean on_click, double context_frac);
extern gboolean cmacs_libregnum_render_ctx_click_focuses
                              (CmacsLibregnumRenderCtx *r);

/* ── Background ──────────────────────────────────────────────────
 * What fills the viewport behind the scene.  Drawn as a 2D blit right
 * after the clear and before anything 3D, so it is genuinely behind
 * everything and costs one textured quad.
 *
 * The procedural kinds are generated once into a texture and cached
 * until the size or the parameters change -- regenerating a starfield
 * per frame would be both slow and a scene that shimmers.
 *
 * TOP/BOTTOM are 0xRRGGBBAA.  For SOLID only TOP is used; for IMAGE both
 * are ignored and PATH is loaded (aspect-preserving cover fit, so a
 * wallpaper of any shape fills the viewport without distorting). */
typedef enum
{
  CMACS_LIBREGNUM_BG_NONE = 0,   /* the flat default clear colour */
  CMACS_LIBREGNUM_BG_SOLID,
  CMACS_LIBREGNUM_BG_GRADIENT,
  CMACS_LIBREGNUM_BG_STARFIELD,
  CMACS_LIBREGNUM_BG_NEBULA,
  CMACS_LIBREGNUM_BG_IMAGE,
  /* Pixels pulled from a registered frame source each frame -- see
   * cmacs_libregnum_render_ctx_set_background_source. */
  CMACS_LIBREGNUM_BG_SOURCE
} CmacsLibregnumBackgroundKind;

/* A live source of ARGB8888 frames for the SOURCE background.
 *
 * Returns non-zero and fills the out params when a frame is available.
 * PIXELS is borrowed and must stay valid for the duration of the call;
 * GENERATION identifies the frame so the same one is not re-uploaded.
 * Returning zero means "nothing new", never an error -- the previous
 * frame keeps being drawn.
 *
 * A function pointer rather than a direct call into the screensaver
 * subsystem on purpose: libregnum must not depend on an optional
 * subsystem that may not be compiled in, and anything able to produce
 * ARGB frames should be able to feed this. */
typedef int (*CmacsLibregnumFrameSource) (gpointer user_data,
                                          const void **pixels,
                                          int *w, int *h,
                                          unsigned long long *generation);

extern void cmacs_libregnum_render_ctx_set_background_source
                              (CmacsLibregnumRenderCtx *r,
                               CmacsLibregnumFrameSource fn,
                               gpointer user_data,
                               GDestroyNotify notify);

/* Returns FALSE only for IMAGE with a file that cannot be loaded -- in
 * which case the background is left as it was, because a viewport that
 * goes blank is a worse answer than one that ignores a bad path. */
extern gboolean cmacs_libregnum_render_ctx_set_background
                              (CmacsLibregnumRenderCtx *r,
                               CmacsLibregnumBackgroundKind kind,
                               guint32 top, guint32 bottom,
                               const char *path);
extern CmacsLibregnumBackgroundKind
       cmacs_libregnum_render_ctx_get_background (CmacsLibregnumRenderCtx *r);

/* ── Particles ───────────────────────────────────────────────────
 * A thin lease on libregnum's LrgParticleSystem, owned by the render
 * context because the update+draw has to happen inside the FBO's 3D
 * pass and nothing outside this file gets to be there.
 *
 * Two shapes, which is all a graph view needs: persistent ambient
 * emitters that make a region feel alive, and one-shot bursts that mark
 * something happening (a selection, a department opening).  Colours are
 * 0xRRGGBBAA to match every other colour in this API.
 *
 * The system is created lazily on first use and destroyed with the
 * context, so a view that never asks for particles pays nothing. */
extern void     cmacs_libregnum_render_ctx_particles_set_enabled
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_particles_enabled
                              (CmacsLibregnumRenderCtx *r);
/* Drop every emitter and every live particle. */
extern void     cmacs_libregnum_render_ctx_particles_clear
                              (CmacsLibregnumRenderCtx *r);
/* A persistent emitter drifting outward from a sphere of RADIUS around
 * (X,Y,Z), RATE particles/second.  Returns FALSE when particles are off
 * or the system could not be created. */
extern gboolean cmacs_libregnum_render_ctx_particles_add_emitter
                              (CmacsLibregnumRenderCtx *r,
                               float x, float y, float z,
                               float radius, float rate,
                               guint32 rgba_start, guint32 rgba_end,
                               float size, float life, float speed);
/* COUNT particles at once from (X,Y,Z) -- a marker for an event. */
extern gboolean cmacs_libregnum_render_ctx_particles_burst
                              (CmacsLibregnumRenderCtx *r,
                               float x, float y, float z, guint count,
                               guint32 rgba_start, guint32 rgba_end,
                               float size, float life, float speed);
/* Live particle count, for tests: it is the only externally visible
 * proof that a burst did anything. */
extern guint    cmacs_libregnum_render_ctx_particles_count
                              (CmacsLibregnumRenderCtx *r);

/* ── Spatial navigation ──────────────────────────────────────────
 * Nearest node to FROM within a screen-space cone pointing (DX,DY)
 * (y downward, need not be normalised).  CONE_COS is the minimum
 * cosine of the angle to that axis; 0.7071 is a 45-degree half-cone.
 * -1 when nothing qualifies.
 *
 * In C because the alternative is one projection call per candidate per
 * keypress from Lisp, against a camera that may be mid-tween. */
extern gint cmacs_libregnum_render_ctx_nearest_in_direction
                              (CmacsLibregnumRenderCtx *r, gint from,
                               double dx, double dy, int vw, int vh,
                               double cone_cos, gboolean visible_only);

/* TRUE when node ID projects inside the viewport, inset by MARGIN_PX.
 * Lets a caller move the camera only when the target would otherwise be
 * off-screen -- flying on every step invalidates the very projection
 * the spatial keys navigate by. */
extern gboolean cmacs_libregnum_render_ctx_node_onscreen_p
                              (CmacsLibregnumRenderCtx *r, gint id,
                               int vw, int vh, double margin_px);

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
/* Move node ID's pick box.  Scene builders that mutate their drawables
 * in place (an animated layout, a dragged node) must call this as well,
 * or picking and labelling keep pointing at the old position. */
extern void cmacs_libregnum_render_ctx_move_node
                              (CmacsLibregnumRenderCtx *r, gint id,
                               float x, float y, float z);
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

/* Bounding box of the non-background pixels in a freshly rendered
 * frame, in DISPLAYED orientation (y downward, matching what `project'
 * and `label_at' report).  Synchronous, so it works headless.
 *
 * For automated render verification: a snapshot proves pixels changed,
 * this proves they changed in the right place -- which matters because
 * the colour attachment is bottom-up while the blit flips it, so an
 * overlay pass that forgets the flip still changes pixels, just
 * mirrored.  FALSE when the frame is entirely background. */
/* Mean colour of the rendered frame, 0-255 per channel.
 *
 * The colour counterpart to ink_bbox, and there for the same reason: a
 * test that can only ask "did pixels change?" cannot catch a frame
 * rendered in the wrong palette, which is what a swapped red/blue
 * channel produces -- a plausible picture, not a corrupt one. */
extern gboolean cmacs_libregnum_render_ctx_mean_color
                              (CmacsLibregnumRenderCtx *r,
                               int *out_r, int *out_g, int *out_b);

extern gboolean cmacs_libregnum_render_ctx_ink_bbox
                              (CmacsLibregnumRenderCtx *r,
                               int *minx, int *miny, int *maxx, int *maxy);

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
/* ARGV, when non-NULL, is a NULL-terminated main()-style argument vector
 * (argv[0] is a synthetic program name); it is applied to the loaded game via
 * the libregnum LrgConfigurable interface before startup, so a per-instance
 * config can be passed (e.g. a screensaver module's CLI flags). A parse error
 * warns but does not abort the load. Pass NULL for no arguments. */
extern gboolean cmacs_libregnum_render_ctx_load_game
                              (CmacsLibregnumRenderCtx *r,
                               const char *so_path,
                               const char *const *argv,
                               char **error_msg);
extern void cmacs_libregnum_render_ctx_unload_game
                              (CmacsLibregnumRenderCtx *r);
/* Host an already-constructed LrgGameTemplate* (transfer full) -- the
 * cmacs-lrgscript elisp-game path.  GAME_TEMPLATE is a void* (LrgGameTemplate*)
 * so lisp-side callers need not see <libregnum.h>. */
extern gboolean cmacs_libregnum_render_ctx_host_game
                              (CmacsLibregnumRenderCtx *r,
                               void *game_template,
                               char **error_msg);
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

/* ── 2D image-display mode (imgedit / vidstudio live viewport) ──────────
 * A content-agnostic live viewport: displays a composited RGBA image as a
 * pan/zoomed textured quad over a checkerboard, with a 2D overlay.  Setters
 * only stash state + a pending-upload flag (safe from any DEFUN); the GPU
 * upload/draw happens at frame top inside render_to_bgra. */
extern void     cmacs_libregnum_render_ctx_image_enter
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_is_image
                              (CmacsLibregnumRenderCtx *r);
/* Bind an LrgImageDocument* (borrowed, re-flattened each refresh — imgedit
 * zero-copy path); or upload an owned GrlImage* (transfer full — vidstudio
 * per-frame); or copy a raw RGBA8 buffer (paste/screenshot). */
extern void     cmacs_libregnum_render_ctx_image_set_document
                              (CmacsLibregnumRenderCtx *r, void *lrg_doc);
extern void     cmacs_libregnum_render_ctx_image_set_grl_image
                              (CmacsLibregnumRenderCtx *r, void *grl_image);
extern void     cmacs_libregnum_render_ctx_image_upload_rgba
                              (CmacsLibregnumRenderCtx *r, int w, int h,
                               const guint8 *rgba, gsize n);
extern void     cmacs_libregnum_render_ctx_image_refresh
                              (CmacsLibregnumRenderCtx *r);
extern void     cmacs_libregnum_render_ctx_image_refresh_rect
                              (CmacsLibregnumRenderCtx *r,
                               int x, int y, int w, int h);
/* Pan/zoom + coordinate mapping. */
extern void     cmacs_libregnum_render_ctx_image_set_view
                              (CmacsLibregnumRenderCtx *r, double scale,
                               double pan_x, double pan_y);
extern void     cmacs_libregnum_render_ctx_image_get_view
                              (CmacsLibregnumRenderCtx *r, double *scale,
                               double *pan_x, double *pan_y);
extern void     cmacs_libregnum_render_ctx_image_zoom_at
                              (CmacsLibregnumRenderCtx *r, double vx,
                               double vy, double factor);
extern void     cmacs_libregnum_render_ctx_image_fit
                              (CmacsLibregnumRenderCtx *r, int vw, int vh);
extern gboolean cmacs_libregnum_render_ctx_image_view_to_doc
                              (CmacsLibregnumRenderCtx *r, double vx,
                               double vy, int *dx, int *dy);
/* Overlay params (doc coords). */
extern void     cmacs_libregnum_render_ctx_image_set_checker
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern void     cmacs_libregnum_render_ctx_image_set_grid
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern void     cmacs_libregnum_render_ctx_image_set_cursor
                              (CmacsLibregnumRenderCtx *r, double dx,
                               double dy, double radius);
extern void     cmacs_libregnum_render_ctx_image_timeline_clear
                              (CmacsLibregnumRenderCtx *r);
extern void     cmacs_libregnum_render_ctx_image_timeline_add_clip
                              (CmacsLibregnumRenderCtx *r, int id, int track,
                               int start, int dur, guint8 cr, guint8 cg,
                               guint8 cb);
extern void     cmacs_libregnum_render_ctx_image_set_label_font
                              (CmacsLibregnumRenderCtx *r, const char *path);
extern gboolean cmacs_libregnum_render_ctx_image_timeline_hit
                              (CmacsLibregnumRenderCtx *r, double vx, double vy,
                               int vw, int vh, int *frame, int *clip_id,
                               int *edge);
extern void     cmacs_libregnum_render_ctx_image_timeline_set
                              (CmacsLibregnumRenderCtx *r, int playhead,
                               int total, int ntracks);
extern void     cmacs_libregnum_render_ctx_image_set_marquee
                              (CmacsLibregnumRenderCtx *r, gboolean on,
                               int x, int y, int w, int h);

/* ── 2D chart mode (cmacs-calculator) ──────────────────────────────────
 * Draws an LrgChart widget into the FBO instead of the 3D scene, mirroring
 * the image mode above.  The widget is built and populated by
 * cmacs/calculator/ (the only place that knows LrgChart); this ctx sizes it
 * to the view and draws it at frame top, inside the render bracket where the
 * GL context is current.  Setting the widget from a DEFUN is safe -- it only
 * stashes a ref.
 *
 * Works unchanged under pgtk and under `emacs --lrg': both backends funnel
 * through render_to_bgra, which passes DST==NULL for the lrg FBO-only path. */
extern void     cmacs_libregnum_render_ctx_chart_enter
                              (CmacsLibregnumRenderCtx *r, gboolean on);
extern gboolean cmacs_libregnum_render_ctx_is_chart
                              (CmacsLibregnumRenderCtx *r);
/* Set the chart widget (an LrgChart*, as an opaque pointer so this header
 * stays raylib/graylib-free).  Takes a ref; pass NULL to drop. */
extern void     cmacs_libregnum_render_ctx_chart_set_widget
                              (CmacsLibregnumRenderCtx *r, void *lrg_chart);
/* Borrowed LrgChart*, or NULL. */
extern void    *cmacs_libregnum_render_ctx_chart_get_widget
                              (CmacsLibregnumRenderCtx *r);
extern void     cmacs_libregnum_render_ctx_chart_set_background
                              (CmacsLibregnumRenderCtx *r, guint8 cr,
                               guint8 cg, guint8 cb, guint8 ca);

#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_RENDER_H */
