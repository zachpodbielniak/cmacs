/* cmacs-libregnum-render.c --- raylib/libregnum render helpers.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * This file is the ONLY place that includes raylib.h directly --
 * raylib defines `Color' as a struct, while cmacs's pgtkgui.h
 * defines `Color' as a void*.  The two cannot coexist in one
 * translation unit, so we keep this file free of all cmacs
 * internals (lisp.h, frame.h, buffer.h) and expose a plain-C
 * API that cmacs-libregnum-view.c calls. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "cmacs-libregnum-render.h"

/* Expose libregnum's editor authoring layer (LrgEditor/LrgLevel/...) from the
 * umbrella header.  The symbols ship in the linked liblibregnum.a (built with
 * BUILD_EDITOR=1, the default); this only makes their declarations visible so
 * the editor host path below can call them. */
#ifndef LRG_BUILD_EDITOR
#define LRG_BUILD_EDITOR 1
#endif

#include <libregnum.h>
#include <graylib.h>
#include <raylib.h>
#include <rlgl.h>     /* rlBegin/rlVertex3f/rlSetTexture for the tilemap quad */
#include <glib.h>
#include <string.h>
#include <math.h>
#include <cairo.h>

/* Desktop GL 3.3 (GLFW backend) -- we read the FBO colour attachment
 * back with a raw glReadPixels in GL_BGRA so the driver does the
 * RGBA->BGRA channel swap for free (no CPU convert loop).  raylib.h is
 * only the API header here; it does not pull in the GL loader, so
 * including the system GL header in this TU is safe and gives us the
 * glReadPixels prototype + GL_BGRA enum. */
#include <GL/gl.h>

/* ── Process-shared hidden raylib window ────────────────────────── */

static LrgGrlWindow *shared_window  = NULL;
static LrgEngine    *shared_engine  = NULL;
static guint         shared_refs    = 0;

gboolean
cmacs_libregnum_render_window_acquire (gchar **error_msg)
{
  shared_refs++;
  /* Create the hidden window + engine exactly once and keep them resident
   * for the process lifetime.  raylib cannot reliably re-create its GL
   * context / FBOs after a CloseWindow + later InitWindow cycle
   * (LoadRenderTexture then fails with "Framebuffer object can not be
   * created"), so once the context exists we reuse it -- views come and go
   * but the shared window does not (see ..._window_release). */
  if (shared_window != NULL) return TRUE;

  SetTraceLogLevel (LOG_WARNING);
  SetConfigFlags (FLAG_WINDOW_HIDDEN);

  shared_window = lrg_grl_window_new (1, 1, "cmacs-libregnum-hidden");
  if (!shared_window)
    {
      if (error_msg)
        *error_msg = g_strdup ("cmacs-libregnum: failed to open "
                               "hidden raylib window (no GL context?)");
      shared_refs = 0;
      return FALSE;
    }

  shared_engine = lrg_engine_get_default ();
  lrg_engine_set_window (shared_engine, LRG_WINDOW (shared_window));

  GError *eng_err = NULL;
  if (!lrg_engine_startup (shared_engine, &eng_err))
    {
      if (error_msg)
        *error_msg = g_strdup (eng_err ? eng_err->message
                                       : "lrg_engine_startup failed");
      if (eng_err) g_error_free (eng_err);
      g_clear_object (&shared_window);
      shared_engine = NULL;
      shared_refs = 0;
      return FALSE;
    }
  return TRUE;
}

void
cmacs_libregnum_render_window_release (void)
{
  /* Deliberately keep the hidden window + engine resident even after the
   * last view is destroyed: raylib's CloseWindow followed by a later
   * InitWindow leaves rlgl unable to create FBOs, which broke loading a
   * second scene or game in the same session.  The hidden window is tiny
   * and idle, so we keep it (and the shared engine) until the process
   * exits rather than tear down a GL context we cannot cleanly rebuild. */
  if (shared_refs > 0)
    shared_refs--;
}

LrgWindow *
cmacs_libregnum_render_get_shared_window (void)
{
  return shared_window ? LRG_WINDOW (shared_window) : NULL;
}

/* ── Scene node model ────────────────────────────────────────────
 *
 * A scene builder (currently the project tree) records one entry per
 * pickable/labelable node here, in parallel with the drawables it
 * emits.  This plain-C table is the backbone for picking (ray vs the
 * node AABB), in-scene labels (project the node center to screen) and
 * the Lisp-side navigation model (exposed via defuns).  Node id == the
 * index into this array. */
typedef struct
{
  gchar   *path;          /* absolute path, owned */
  gchar   *name;          /* basename, owned */
  gboolean is_dir;
  int      depth;
  int      parent;        /* node index, -1 for root */
  float    x, y, z;       /* center */
  float    hw, hh, hd;    /* half-extents (AABB) */
  int      label_mode;    /* CmacsLibregnumLabelMode; -1 == legacy default */
} CmacsNode;

static void
cmacs_node_clear (gpointer p)
{
  CmacsNode *n = p;
  g_clear_pointer (&n->path, g_free);
  g_clear_pointer (&n->name, g_free);
}

/* A persistent map label (country/region name) at a fixed world point,
 * projected + drawn by the overlay.  Parallel to but independent of the
 * pickable node table, so it survives marker rebuilds. */
typedef struct
{
  float    x, y, z;
  gchar   *text;        /* owned */
  guint8   r, g, b;
} CmacsMapLabel;

static void
cmacs_map_label_clear (gpointer p)
{
  CmacsMapLabel *l = p;
  g_clear_pointer (&l->text, g_free);
}

/* A persistent camera-facing billboard (e.g. a country flag) at a fixed
 * world point, drawn each frame via raylib DrawBillboard. */
typedef struct
{
  float       x, y, z, size;
  GrlTexture *tex;       /* owned */
} CmacsBillboard;

static void
cmacs_billboard_clear (gpointer p)
{
  CmacsBillboard *b = p;
  g_clear_object (&b->tex);
}

/* ── Per-view render context (opaque to view.c) ────────────────── */

#ifdef LRG_BUILD_EDITOR
/* A loaded mesh-asset instance baked from a MESH_ASSET node: the GPU model
 * plus the node's transform, drawn each frame in the 3D layer (LrgShape3D
 * drawables can't host an arbitrary glTF/OBJ model). */
typedef struct
{
  GrlModel   *model;           /* owned, or NULL */
  GrlTexture *texture;         /* owned, or NULL */
  gboolean    flat;            /* texture: TRUE = flat ground quad,
                                  FALSE = camera-facing billboard (sprite) */
  /* Tilemap: when `tiles' is non-NULL the texture is a tileset and the entry
   * draws an mw*mh grid of per-cell tiles (tile index -> tileset sub-rect). */
  gint       *tiles;           /* owned: mw*mh ints, -1 = empty, or NULL */
  guint8     *tile_rgb;        /* owned: 3*mw*mh, per-cell colour sampled from
                                  the tileset (raylib rlgl texturing does not
                                  composite in the graylib FBO batch, so tiles
                                  render as colour-sampled cells) */
  int         mw, mh;          /* map size in tiles */
  int         tw, th;          /* tile pixel size in the tileset */
  int         cols;            /* tileset columns */
  /* Per-tile textured plane models (tile-index -> GrlModel*), with the tile's
   * tileset sub-rect on the albedo map; drawn via the working mesh path.  The
   * sub-textures are kept alive in tile_textures.  Falls back to tile_rgb
   * colour cells when a model is missing. */
  GHashTable *tile_models;
  GPtrArray  *tile_textures;
  float       x, y, z;
  float       rx, ry, rz;      /* euler radians */
  float       sx, sy, sz;
  guint8      cr, cg, cb;
  gint        node_id;          /* baked scene node id (for wireframe param) */
} CmacsEditorModel;
#endif

struct CmacsLibregnumRenderCtx
{
  LrgRenderer    *renderer;
  LrgCamera      *camera;
  /* Flat list of drawables (LrgDrawable*); each scene builder adds
   * primitives here.  Owned ref per element. */
  GPtrArray      *drawables;
  RenderTexture2D fbo;
  gboolean        fbo_valid;
  int             width, height;

  /* Scene node model (CmacsNode), parallel to the drawables. */
  GArray         *nodes;
  gint            selected;       /* selected node id, -1 if none */

  /* Camera focus tween (see focus_node / step_focus). */
  gboolean        focusing;
  float           goal_px, goal_py, goal_pz;   /* goal camera position */
  float           goal_tx, goal_ty, goal_tz;   /* goal camera target */

  /* Game-module hosting. When game_mode is TRUE, render_to_bgra drives the
   * loaded game instead of the scene drawables. */
  gboolean          game_mode;
  LrgLoadedGame    *loaded_game;   /* owned */
  /* When TRUE the view captures ALL mouse events on the frame while focused
   * (full-focus, suitable for a game).  When FALSE (the default, suitable for
   * the editor) the view only handles events inside its own window, so clicks
   * in other Emacs panes select them normally. */
  gboolean          mouse_capture_all;
  LrgGameTemplate  *game;          /* borrowed from loaded_game */
  LrgGameHost      *game_host;     /* owned (CmacsFboGameHost) */
  LrgInputSoftware *game_input;    /* owned; registered with input manager */

  /* ── Persistent background model ──────────────────────────────────
   * Drawn first every frame (behind the per-tick scene drawables) and
   * NOT cleared by clear_drawables.  Used by the gnuseye globe: its
   * textured Earth sphere lives here so it survives marker rebuilds.
   * Owned by the ctx; the builder keeps its own refs for texture updates. */
  GrlModel         *background_model;     /* owned, or NULL */
  float             background_spin_deg;  /* rotation about +Y, degrees */

  /* Occluding sphere radius at the origin (the gnuseye globe), or 0 for
   * none.  Labels/billboards on the FAR side of this sphere (behind the
   * limb) are culled so they do not show through the globe. */
  double            occluder_radius;

  /* Persistent static drawables (e.g. the gnuseye coastline overlay):
   * drawn every frame after the background model and NOT cleared by
   * clear_drawables.  Owned (g_object_unref per element). */
  GPtrArray        *static_drawables;

  /* Persistent map labels (country/region names), drawn by the overlay. */
  GArray           *map_labels;       /* CmacsMapLabel */

  /* Persistent camera-facing billboards (e.g. country flags). */
  GArray           *billboards;       /* CmacsBillboard */

  /* Hovered scene node id (-1 none); drives hover label policy. */
  gint              hovered;

#ifdef LRG_BUILD_EDITOR
  /* Editor / level authoring.  When `editor' is non-NULL the view hosts an
   * editable level: its nodes are baked into the scene drawables each
   * rebuild, so it renders through the normal scene path (NOT game_mode).
   * editor_node_map[i] is the LrgNode* (borrowed) for scene node id i. */
  LrgEditor        *editor;          /* owned */
  GPtrArray        *editor_node_map; /* borrowed LrgNode*, parallel to nodes */
  GArray           *editor_models;   /* CmacsEditorModel, drawn each frame */
  gboolean          playing;         /* play-in-editor: world is running */
  LrgWorld         *play_world;      /* owned during play */

  /* Mouse drag-to-move state.  During a drag the node is moved *live* with
   * the plain setter (no undo command); a single coalesced transform command
   * is pushed on drag-end, so one drag == one undo step. */
  gboolean          editor_dragging;
  gint              editor_drag_id;       /* baked node id being dragged */
  float             editor_drag_start[3]; /* node location at drag begin */
  float             editor_drag_offset[2];/* (x,z) grab offset under cursor */
  float             editor_snap;          /* translate grid (0 = off) */

  /* On-screen transform gizmo: axis handles drawn at the selection that the
   * user drags for axis-constrained translate / rotate / scale. */
  int               gizmo_tool;     /* 0 select, 1 translate, 2 rotate, 3 scale */
  int               gizmo_axis;     /* active drag axis: 0=X 1=Y 2=Z, -1 none */
  gboolean          gizmo_dragging;
  float             gizmo_start[3]; /* node loc/rot/scale triple at drag start */
  float             gizmo_center0[3];/* selection center at grab (fixed axis origin) */
  float             gizmo_grab;     /* axis parameter / angle at grab */

  gboolean          place_armed;    /* next viewport click drops the armed asset */

  /* ── Feature: real-time scene shading ─────────────────────────────── */
  /* Blinn-Phong lighting shader + material.  Lazily created on first
   * enable (cmacs_libregnum_render_ctx_editor_set_shading).  When
   * `shading' is TRUE, MESH_ASSET models use lighting_material which has
   * lighting_shader bound, and up to 4 LIGHT nodes are pushed to the
   * shader each frame.  When FALSE the models draw unlit (default). */
  GrlShader        *lighting_shader;   /* owned; NULL until first enable */
  GrlMaterial      *lighting_material; /* owned; NULL until first enable */
  gboolean          shading;           /* TRUE = lit render mode */

  /* ── Feature: look-through camera ─────────────────────────────────── */
  /* When camera_lookthrough is TRUE, ctx_raylib_camera() builds the
   * Camera3D from the CAMERA node at camera_lookthrough_id rather than
   * the orbit camera.  Orbit/pan/zoom/focus are suppressed while active. */
  gboolean          camera_lookthrough;
  gint              camera_lookthrough_id;
#endif
};

CmacsLibregnumRenderCtx *
cmacs_libregnum_render_ctx_new (int w, int h)
{
  if (!shared_window) return NULL;
  CmacsLibregnumRenderCtx *r = g_new0 (CmacsLibregnumRenderCtx, 1);
  r->width  = w;
  r->height = h;
  r->selected = -1;
  r->hovered = -1;
  r->renderer  = lrg_renderer_new (LRG_WINDOW (shared_window));
  r->drawables = g_ptr_array_new_with_free_func (g_object_unref);
  r->static_drawables = g_ptr_array_new_with_free_func (g_object_unref);
  r->map_labels = g_array_new (FALSE, TRUE, sizeof (CmacsMapLabel));
  g_array_set_clear_func (r->map_labels, cmacs_map_label_clear);
  r->billboards = g_array_new (FALSE, TRUE, sizeof (CmacsBillboard));
  g_array_set_clear_func (r->billboards, cmacs_billboard_clear);
  r->nodes = g_array_new (FALSE, TRUE, sizeof (CmacsNode));
  g_array_set_clear_func (r->nodes, cmacs_node_clear);

  LrgCamera3D *cam = lrg_camera3d_new ();
  lrg_camera3d_set_position_xyz (cam, 8.0f, 6.0f, 12.0f);
  lrg_camera3d_set_target_xyz   (cam, 0.0f, 0.0f,  0.0f);
  lrg_camera3d_set_fovy         (cam, 60.0f);
  r->camera = LRG_CAMERA (cam);
  lrg_renderer_set_camera (r->renderer, r->camera);

  r->fbo = LoadRenderTexture (w, h);
  r->fbo_valid = (r->fbo.id != 0);
  return r;
}

void
cmacs_libregnum_render_ctx_free (CmacsLibregnumRenderCtx *r)
{
  if (!r) return;
  if (r->game_mode) cmacs_libregnum_render_ctx_unload_game (r);
#ifdef LRG_BUILD_EDITOR
  g_clear_object (&r->editor);
  g_clear_object (&r->play_world);
  if (r->editor_node_map) g_ptr_array_unref (r->editor_node_map);
  if (r->editor_models)
    {
      guint mi;
      for (mi = 0; mi < r->editor_models->len; mi++)
        {
          CmacsEditorModel *em = &g_array_index (r->editor_models,
                                                 CmacsEditorModel, mi);
          g_clear_object (&em->model);
          g_clear_object (&em->texture);
          g_clear_pointer (&em->tiles, g_free);
          g_clear_pointer (&em->tile_rgb, g_free);
          g_clear_pointer (&em->tile_models, g_hash_table_destroy);
          g_clear_pointer (&em->tile_textures, g_ptr_array_unref);
        }
      g_array_free (r->editor_models, TRUE);
    }
  /* Shading resources. */
  g_clear_object (&r->lighting_shader);
  g_clear_object (&r->lighting_material);
#endif
  if (r->fbo_valid) UnloadRenderTexture (r->fbo);
  g_clear_object (&r->background_model);
  if (r->static_drawables) g_ptr_array_unref (r->static_drawables);
  if (r->map_labels) g_array_free (r->map_labels, TRUE);
  if (r->billboards) g_array_free (r->billboards, TRUE);
  g_clear_object (&r->camera);
  if (r->drawables) g_ptr_array_unref (r->drawables);
  if (r->nodes) g_array_free (r->nodes, TRUE);
  g_clear_object (&r->renderer);
  g_free (r);
}

void
cmacs_libregnum_render_ctx_resize (CmacsLibregnumRenderCtx *r, int w, int h)
{
  if (!r) return;
  if (w == r->width && h == r->height) return;
  if (r->fbo_valid) { UnloadRenderTexture (r->fbo); r->fbo_valid = FALSE; }
  r->fbo = LoadRenderTexture (w, h);
  r->fbo_valid = (r->fbo.id != 0);
  r->width = w; r->height = h;
}

void *
cmacs_libregnum_render_ctx_get_renderer (CmacsLibregnumRenderCtx *r)
{ return r ? r->renderer : NULL; }
void *
cmacs_libregnum_render_ctx_get_scene (CmacsLibregnumRenderCtx *r)
{ return r ? (void *) r->drawables : NULL; }

void
cmacs_libregnum_render_ctx_add_drawable (CmacsLibregnumRenderCtx *r,
                                         void *drawable)
{
  if (!r || !drawable) return;
  /* Caller transfers ownership; ptr_array's free-func g_object_unref
   * releases on removal/free. */
  g_ptr_array_add (r->drawables, drawable);
}

/* ── Persistent background model (gnuseye globe) ─────────────────── */

void
cmacs_libregnum_render_ctx_set_background_model (CmacsLibregnumRenderCtx *r,
                                                 void *model)
{
  if (!r) return;
  if (r->background_model == (GrlModel *) model) return;
  g_clear_object (&r->background_model);
  r->background_model = (GrlModel *) model;   /* takes ownership */
}

void *
cmacs_libregnum_render_ctx_get_background_model (CmacsLibregnumRenderCtx *r)
{
  return r ? r->background_model : NULL;
}

void
cmacs_libregnum_render_ctx_set_background_spin (CmacsLibregnumRenderCtx *r,
                                                double deg)
{
  if (r) r->background_spin_deg = (float) deg;
}

void
cmacs_libregnum_render_ctx_set_occluder_radius (CmacsLibregnumRenderCtx *r,
                                                double radius)
{
  if (r) r->occluder_radius = radius;
}

/* TRUE if world point (X,Y,Z) is on the near side of the occluding sphere
 * (visible to the camera), i.e. not hidden behind the globe.  A surface
 * point P at radius R is visible from camera C iff dot(P,C) > R*R; this
 * also passes points well above the surface (satellites, lifted labels). */
static gboolean
ctx_point_near_side (CmacsLibregnumRenderCtx *r, double x, double y, double z)
{
  if (!r || r->occluder_radius <= 0.0) return TRUE;
  double px, py, pz, tx, ty, tz, fov;
  cmacs_libregnum_render_ctx_get_camera_state (r, &px, &py, &pz,
                                               &tx, &ty, &tz, &fov);
  double dot = x * px + y * py + z * pz;
  return dot > r->occluder_radius * r->occluder_radius;
}

void
cmacs_libregnum_render_ctx_add_static_drawable (CmacsLibregnumRenderCtx *r,
                                                void *drawable)
{
  if (!r || !drawable) return;
  g_ptr_array_add (r->static_drawables, drawable);   /* ownership transfers */
}

void
cmacs_libregnum_render_ctx_clear_static_drawables (CmacsLibregnumRenderCtx *r)
{
  if (r && r->static_drawables)
    g_ptr_array_set_size (r->static_drawables, 0);
}

/* ── Map labels ──────────────────────────────────────────────────── */

void
cmacs_libregnum_render_ctx_add_map_label (CmacsLibregnumRenderCtx *r,
                                          float x, float y, float z,
                                          const char *text,
                                          guint8 cr, guint8 cg, guint8 cb)
{
  if (!r || !r->map_labels) return;
  CmacsMapLabel l = { 0 };
  l.x = x; l.y = y; l.z = z;
  l.text = g_strdup (text ? text : "");
  l.r = cr; l.g = cg; l.b = cb;
  g_array_append_val (r->map_labels, l);
}

void
cmacs_libregnum_render_ctx_clear_map_labels (CmacsLibregnumRenderCtx *r)
{
  if (r && r->map_labels) g_array_set_size (r->map_labels, 0);
}

guint
cmacs_libregnum_render_ctx_map_label_count (CmacsLibregnumRenderCtx *r)
{
  return (r && r->map_labels) ? r->map_labels->len : 0;
}

/* Project map label ID to view-local pixels + report its TEXT (borrowed)
 * and colour.  FALSE if out of range or behind the camera (so back-of-globe
 * labels are hidden). */
gboolean
cmacs_libregnum_render_ctx_map_label_at (CmacsLibregnumRenderCtx *r, guint id,
                                         int vw, int vh, double *sx, double *sy,
                                         const char **text,
                                         guint8 *cr, guint8 *cg, guint8 *cb)
{
  if (!r || !r->map_labels || id >= r->map_labels->len) return FALSE;
  CmacsMapLabel *l = &g_array_index (r->map_labels, CmacsMapLabel, id);
  /* Hide labels on the far side of the globe (behind the limb). */
  if (!ctx_point_near_side (r, l->x, l->y, l->z)) return FALSE;
  if (!cmacs_libregnum_render_ctx_project (r, l->x, l->y, l->z, vw, vh, sx, sy))
    return FALSE;
  if (text) *text = l->text;
  if (cr) *cr = l->r;
  if (cg) *cg = l->g;
  if (cb) *cb = l->b;
  return TRUE;
}

/* Distance from the camera to the origin (the globe centre); lets the
 * overlay show map labels only once the user has zoomed in. */
double
cmacs_libregnum_render_ctx_camera_distance (CmacsLibregnumRenderCtx *r)
{
  if (!r) return 0.0;
  double px, py, pz, tx, ty, tz, fov;
  cmacs_libregnum_render_ctx_get_camera_state (r, &px, &py, &pz,
                                               &tx, &ty, &tz, &fov);
  return sqrt (px*px + py*py + pz*pz);
}

/* ── Billboards (country flags) ──────────────────────────────────── */

void
cmacs_libregnum_render_ctx_add_billboard (CmacsLibregnumRenderCtx *r,
                                          float x, float y, float z,
                                          void *texture, float size)
{
  if (!r || !r->billboards || !texture) return;
  CmacsBillboard b = { 0 };
  b.x = x; b.y = y; b.z = z; b.size = size;
  b.tex = (GrlTexture *) texture;     /* ownership transfers */
  g_array_append_val (r->billboards, b);
}

void
cmacs_libregnum_render_ctx_clear_billboards (CmacsLibregnumRenderCtx *r)
{
  if (r && r->billboards) g_array_set_size (r->billboards, 0);
}

guint
cmacs_libregnum_render_ctx_billboard_count (CmacsLibregnumRenderCtx *r)
{
  return (r && r->billboards) ? r->billboards->len : 0;
}

/* ── Per-node label policy + hover ───────────────────────────────── */

void
cmacs_libregnum_render_ctx_set_node_label_mode (CmacsLibregnumRenderCtx *r,
                                                gint id, int mode)
{
  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return;
  g_array_index (r->nodes, CmacsNode, id).label_mode = mode;
}

int
cmacs_libregnum_render_ctx_get_node_label_mode (CmacsLibregnumRenderCtx *r,
                                                gint id)
{
  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return -1;
  return g_array_index (r->nodes, CmacsNode, id).label_mode;
}

void
cmacs_libregnum_render_ctx_set_hovered (CmacsLibregnumRenderCtx *r, gint id)
{
  if (r) r->hovered = id;
}

gint
cmacs_libregnum_render_ctx_get_hovered (CmacsLibregnumRenderCtx *r)
{
  return r ? r->hovered : -1;
}

void
cmacs_libregnum_render_ctx_clear_drawables (CmacsLibregnumRenderCtx *r)
{
  if (!r) return;
  g_ptr_array_set_size (r->drawables, 0);
  /* The node model is parallel to the drawables; clear it too so a
   * rebuild starts fresh (and drop any stale selection). */
  if (r->nodes) g_array_set_size (r->nodes, 0);
  r->selected = -1;
  r->focusing = FALSE;
}

/* ── Scene node model API ──────────────────────────────────────── */

guint
cmacs_libregnum_render_ctx_add_node (CmacsLibregnumRenderCtx *r,
                                     const char *path, const char *name,
                                     gboolean is_dir, int depth, int parent,
                                     float x, float y, float z,
                                     float hw, float hh, float hd)
{
  CmacsNode n = { 0 };
  n.path = g_strdup (path ? path : "");
  n.name = g_strdup (name ? name : "");
  n.is_dir = is_dir;
  n.depth = depth;
  n.parent = parent;
  n.x = x; n.y = y; n.z = z;
  n.hw = hw; n.hh = hh; n.hd = hd;
  n.label_mode = -1;   /* legacy: dir-or-selected (see overlay) */
  g_array_append_val (r->nodes, n);
  return r->nodes->len - 1;
}

guint
cmacs_libregnum_render_ctx_node_count (CmacsLibregnumRenderCtx *r)
{
  return (r && r->nodes) ? r->nodes->len : 0;
}

/* Borrowed pointers; valid until the next clear/rebuild. */
gboolean
cmacs_libregnum_render_ctx_node_info (CmacsLibregnumRenderCtx *r, guint id,
                                      const char **path, const char **name,
                                      gboolean *is_dir, int *depth,
                                      int *parent)
{
  if (!r || !r->nodes || id >= r->nodes->len) return FALSE;
  CmacsNode *n = &g_array_index (r->nodes, CmacsNode, id);
  if (path)   *path   = n->path;
  if (name)   *name   = n->name;
  if (is_dir) *is_dir = n->is_dir;
  if (depth)  *depth  = n->depth;
  if (parent) *parent = n->parent;
  return TRUE;
}

void
cmacs_libregnum_render_ctx_set_selected (CmacsLibregnumRenderCtx *r, gint id)
{
  if (!r) return;
  r->selected = (id >= 0 && r->nodes && (guint) id < r->nodes->len) ? id : -1;
}

gint
cmacs_libregnum_render_ctx_get_selected (CmacsLibregnumRenderCtx *r)
{
  return r ? r->selected : -1;
}

/* Build a raylib Camera3D snapshot from the live LrgCamera3D.
 *
 * Feature: look-through camera.  When camera_lookthrough is TRUE, we build
 * the Camera3D from the CAMERA node at camera_lookthrough_id: position from
 * the node's world location, yaw/pitch from the node's rotation, fov from
 * the "fov" visual param.  All other callers (pick, project, gizmo, etc.)
 * call ctx_raylib_camera() so they all stay consistent with the override. */
static Camera3D
ctx_raylib_camera (CmacsLibregnumRenderCtx *r)
{
  Camera3D c = { 0 };
  c.up = (Vector3){ 0.0f, 1.0f, 0.0f };
  c.fovy = 60.0f;
  c.projection = CAMERA_PERSPECTIVE;

#ifdef LRG_BUILD_EDITOR
  /* Look-through override: build camera from a CAMERA node's pose. */
  if (r && r->camera_lookthrough && r->editor_node_map
      && r->camera_lookthrough_id >= 0
      && (guint) r->camera_lookthrough_id < r->editor_node_map->len)
    {
      LrgNode      *ln = g_ptr_array_index (r->editor_node_map,
                                            r->camera_lookthrough_id);
      LrgNodeVisual *lv = ln ? lrg_node_get_visual (ln) : NULL;
      if (ln)
        {
          GrlVector3 *loc = lrg_node_get_location (ln);
          GrlVector3 *rot = lrg_node_get_rotation (ln);
          float px = loc ? loc->x : 0.0f;
          float py = loc ? loc->y : 0.0f;
          float pz = loc ? loc->z : 0.0f;
          float yaw   = rot ? rot->y : 0.0f;
          float pitch = rot ? rot->x : 0.0f;
          /* Forward vector from yaw + pitch (OpenGL right-hand, -Z forward). */
          float fwd_x = -sinf (yaw) * cosf (pitch);
          float fwd_y =  sinf (pitch);
          float fwd_z = -cosf (yaw) * cosf (pitch);
          float fov   = lv ? (float)
                          lrg_node_visual_get_param_double (lv, "fov", 50.0)
                           : 50.0f;
          c.position   = (Vector3){ px, py, pz };
          c.target     = (Vector3){ px + fwd_x, py + fwd_y, pz + fwd_z };
          c.up         = (Vector3){ 0.0f, 1.0f, 0.0f };
          c.fovy       = fov;
          c.projection = CAMERA_PERSPECTIVE;
          return c;
        }
    }
#endif

  if (r && r->camera && LRG_IS_CAMERA3D (r->camera))
    {
      LrgCamera3D *c3 = LRG_CAMERA3D (r->camera);
      g_autoptr (GrlVector3) p = lrg_camera3d_get_position (c3);
      g_autoptr (GrlVector3) t = lrg_camera3d_get_target   (c3);
      g_autoptr (GrlVector3) u = lrg_camera3d_get_up       (c3);
      if (p) c.position = (Vector3){ p->x, p->y, p->z };
      if (t) c.target   = (Vector3){ t->x, t->y, t->z };
      if (u) c.up       = (Vector3){ u->x, u->y, u->z };
      c.fovy = lrg_camera3d_get_fovy (c3);
      if (lrg_camera3d_get_projection (c3) == LRG_PROJECTION_ORTHOGRAPHIC)
        c.projection = CAMERA_ORTHOGRAPHIC;
    }
  return c;
}

/* Ray-pick the nearest node whose AABB the cursor ray crosses.
 * VX,VY are view-local pixels (origin top-left); VW,VH the view size.
 * Returns the node id, or -1 on a miss. */
gint
cmacs_libregnum_render_ctx_pick (CmacsLibregnumRenderCtx *r,
                                 double vx, double vy, int vw, int vh)
{
  if (!r || !r->nodes || r->nodes->len == 0 || vw <= 0 || vh <= 0)
    return -1;
  Camera3D cam = ctx_raylib_camera (r);
  Ray ray = GetScreenToWorldRayEx ((Vector2){ (float) vx, (float) vy },
                                   cam, vw, vh);
  gint best = -1;
  float best_dist = 0.0f;
  for (guint i = 0; i < r->nodes->len; i++)
    {
      CmacsNode *n = &g_array_index (r->nodes, CmacsNode, i);
      BoundingBox box = {
        (Vector3){ n->x - n->hw, n->y - n->hh, n->z - n->hd },
        (Vector3){ n->x + n->hw, n->y + n->hh, n->z + n->hd }
      };
      RayCollision hit = GetRayCollisionBox (ray, box);
      if (hit.hit && (best < 0 || hit.distance < best_dist))
        {
          best = (gint) i;
          best_dist = hit.distance;
        }
    }
  return best;
}

/* Project a world point to view-local pixels (origin top-left).
 * Returns FALSE if the point is behind the camera. */
gboolean
cmacs_libregnum_render_ctx_project (CmacsLibregnumRenderCtx *r,
                                    float wx, float wy, float wz,
                                    int vw, int vh,
                                    double *sx, double *sy)
{
  if (!r || vw <= 0 || vh <= 0) return FALSE;
  Camera3D cam = ctx_raylib_camera (r);
  /* Behind-camera test: forward . (point - position) must be positive. */
  float fx = cam.target.x - cam.position.x;
  float fy = cam.target.y - cam.position.y;
  float fz = cam.target.z - cam.position.z;
  float vx = wx - cam.position.x;
  float vy = wy - cam.position.y;
  float vz = wz - cam.position.z;
  if (fx * vx + fy * vy + fz * vz <= 0.0f) return FALSE;
  Vector2 s = GetWorldToScreenEx ((Vector3){ wx, wy, wz }, cam, vw, vh);
  if (sx) *sx = s.x;
  if (sy) *sy = s.y;
  return TRUE;
}

/* Project node ID's label anchor (just above its top) to view-local
 * pixels and report its name + type.  Returns FALSE if the node is out
 * of range or behind the camera.  Used by the overlay to draw labels. */
gboolean
cmacs_libregnum_render_ctx_label_at (CmacsLibregnumRenderCtx *r, guint id,
                                     int vw, int vh, double *sx, double *sy,
                                     const char **name, gboolean *is_dir)
{
  if (!r || !r->nodes || id >= r->nodes->len) return FALSE;
  CmacsNode *n = &g_array_index (r->nodes, CmacsNode, id);
  if (name)   *name   = n->name;
  if (is_dir) *is_dir = n->is_dir;
  /* Hide labels for nodes on the far side of the globe. */
  if (!ctx_point_near_side (r, n->x, n->y, n->z)) return FALSE;
  /* Gap above the marker, proportional to its size (so labels sit close to
   * small markers like aircraft) but capped so big nodes (editor cubes)
   * keep their original spacing. */
  float gap = n->hh * 1.6f;
  if (gap > 0.25f) gap = 0.25f;
  return cmacs_libregnum_render_ctx_project (r, n->x, n->y + n->hh + gap,
                                             n->z, vw, vh, sx, sy);
}

/* Aim the camera at node ID: target = node center, position backed off
 * along the current view direction by a distance scaled to node size.
 * Animated by step_focus() over subsequent frames. */
void
cmacs_libregnum_render_ctx_focus_node (CmacsLibregnumRenderCtx *r, gint id)
{
  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return;
#ifdef LRG_BUILD_EDITOR
  if (r->camera_lookthrough) return; /* suppressed during look-through */
#endif
  CmacsNode *n = &g_array_index (r->nodes, CmacsNode, id);
  Camera3D cam = ctx_raylib_camera (r);
  /* Current view direction (from target back to camera), normalized. */
  float dx = cam.position.x - cam.target.x;
  float dy = cam.position.y - cam.target.y;
  float dz = cam.position.z - cam.target.z;
  float len = sqrtf (dx*dx + dy*dy + dz*dz);
  if (len < 1e-3f) { dx = 0; dy = 0.6f; dz = 1.0f; len = sqrtf (0.36f+1.0f); }
  dx /= len; dy /= len; dz /= len;
  float extent = fmaxf (n->hw, fmaxf (n->hh, n->hd));
  float dist = 6.0f + extent * 4.0f;
  r->goal_tx = n->x; r->goal_ty = n->y; r->goal_tz = n->z;
  r->goal_px = n->x + dx * dist;
  r->goal_py = n->y + dy * dist;
  r->goal_pz = n->z + dz * dist;
  r->focusing = TRUE;
}

gboolean
cmacs_libregnum_render_ctx_focus_active (CmacsLibregnumRenderCtx *r)
{
  return r && r->focusing;
}

/* Advance the focus tween one frame; clears `focusing' on arrival. */
static void
ctx_step_focus (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->focusing || !r->camera || !LRG_IS_CAMERA3D (r->camera))
    { if (r) r->focusing = FALSE; return; }
  LrgCamera3D *c3 = LRG_CAMERA3D (r->camera);
  g_autoptr (GrlVector3) p = lrg_camera3d_get_position (c3);
  g_autoptr (GrlVector3) t = lrg_camera3d_get_target   (c3);
  float k = 0.25f;   /* lerp factor per frame */
  float npx = p->x + (r->goal_px - p->x) * k;
  float npy = p->y + (r->goal_py - p->y) * k;
  float npz = p->z + (r->goal_pz - p->z) * k;
  float ntx = t->x + (r->goal_tx - t->x) * k;
  float nty = t->y + (r->goal_ty - t->y) * k;
  float ntz = t->z + (r->goal_tz - t->z) * k;
  lrg_camera3d_set_position_xyz (c3, npx, npy, npz);
  lrg_camera3d_set_target_xyz   (c3, ntx, nty, ntz);
  /* Converged? */
  float dp = fabsf (r->goal_px - npx) + fabsf (r->goal_py - npy)
           + fabsf (r->goal_pz - npz);
  float dt = fabsf (r->goal_tx - ntx) + fabsf (r->goal_ty - nty)
           + fabsf (r->goal_tz - ntz);
  if (dp + dt < 0.05f)
    {
      lrg_camera3d_set_position_xyz (c3, r->goal_px, r->goal_py, r->goal_pz);
      lrg_camera3d_set_target_xyz   (c3, r->goal_tx, r->goal_ty, r->goal_tz);
      r->focusing = FALSE;
    }
}
void *
cmacs_libregnum_render_ctx_get_camera (CmacsLibregnumRenderCtx *r)
{ return r ? r->camera : NULL; }
void
cmacs_libregnum_render_ctx_set_camera (CmacsLibregnumRenderCtx *r, void *cam)
{
  if (!r || !cam || !LRG_IS_CAMERA (cam)) return;
  g_clear_object (&r->camera);
  r->camera = g_object_ref ((LrgCamera *) cam);
  lrg_renderer_set_camera (r->renderer, r->camera);
}

/* ── Embedded game host (implements LrgGameHost) ──────────────────
 *
 * Lets a loaded libregnum game render into this view's FBO. The game
 * borrows cmacs's already-started engine and renders to the FBO; it has
 * no LrgWindow of its own, so it never grabs the host's real cursor.
 * Frame timing is a monotonic clock (raylib's frame time is invalid on
 * the FBO path, which never presents the backbuffer). */

#define CMACS_TYPE_FBO_GAME_HOST (cmacs_fbo_game_host_get_type ())
G_DECLARE_FINAL_TYPE (CmacsFboGameHost, cmacs_fbo_game_host,
                      CMACS, FBO_GAME_HOST, GObject)

struct _CmacsFboGameHost
{
  GObject                  parent_instance;
  CmacsLibregnumRenderCtx *ctx;          /* back-pointer, not owned */
  gint64                   last_tick_us;
};

static void cmacs_fbo_game_host_iface_init (LrgGameHostInterface *iface);

G_DEFINE_TYPE_WITH_CODE (CmacsFboGameHost, cmacs_fbo_game_host, G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (LRG_TYPE_GAME_HOST,
                                                cmacs_fbo_game_host_iface_init))

static void
cmacs_fbo_game_host_class_init (CmacsFboGameHostClass *klass)
{
  (void) klass;
}

static void
cmacs_fbo_game_host_init (CmacsFboGameHost *self)
{
  self->ctx = NULL;
  self->last_tick_us = 0;
}

static LrgEngine *
cfgh_get_engine (LrgGameHost *h)
{
  (void) h;
  return shared_engine;
}

static LrgWindow *
cfgh_get_window (LrgGameHost *h)
{
  (void) h;
  return NULL;               /* no window: never grab the real cursor */
}

static gboolean
cfgh_get_owns_window (LrgGameHost *h)
{
  (void) h;
  return FALSE;
}

static void
cfgh_begin_frame (LrgGameHost *h)
{
  CmacsFboGameHost *self = CMACS_FBO_GAME_HOST (h);
  if (self->ctx && self->ctx->fbo_valid)
    BeginTextureMode (self->ctx->fbo);
}

static void
cfgh_end_frame (LrgGameHost *h)
{
  (void) h;
  EndTextureMode ();
}

static void
cfgh_get_render_size (LrgGameHost *h, gint *w, gint *height)
{
  CmacsFboGameHost *self = CMACS_FBO_GAME_HOST (h);
  if (w)      *w      = self->ctx ? self->ctx->width  : 0;
  if (height) *height = self->ctx ? self->ctx->height : 0;
}

static gdouble
cfgh_get_frame_delta (LrgGameHost *h)
{
  CmacsFboGameHost *self = CMACS_FBO_GAME_HOST (h);
  gint64  now  = g_get_monotonic_time ();
  gint64  prev = self->last_tick_us ? self->last_tick_us : now;
  gdouble dt   = (gdouble) (now - prev) / 1e6;

  self->last_tick_us = now;
  if (dt < 0.0)  dt = 0.0;
  if (dt > 0.25) dt = 0.25;   /* clamp like the template's max_frame_time */
  return dt;
}

static LrgInputSoftware *
cfgh_get_input_source (LrgGameHost *h)
{
  CmacsFboGameHost *self = CMACS_FBO_GAME_HOST (h);
  return self->ctx ? self->ctx->game_input : NULL;
}

static void
cmacs_fbo_game_host_iface_init (LrgGameHostInterface *iface)
{
  iface->get_engine       = cfgh_get_engine;
  iface->get_window       = cfgh_get_window;
  iface->get_owns_window  = cfgh_get_owns_window;
  iface->begin_frame      = cfgh_begin_frame;
  iface->end_frame        = cfgh_end_frame;
  iface->get_render_size  = cfgh_get_render_size;
  iface->get_frame_delta  = cfgh_get_frame_delta;
  iface->get_input_source = cfgh_get_input_source;
  /* clear left NULL: render_to_bgra clears the FBO directly. */
}

static CmacsFboGameHost *
cmacs_fbo_game_host_new (CmacsLibregnumRenderCtx *ctx)
{
  CmacsFboGameHost *h = g_object_new (CMACS_TYPE_FBO_GAME_HOST, NULL);
  h->ctx = ctx;
  return h;
}

/* ── Game lifecycle on the render ctx ─────────────────────────────── */

gboolean
cmacs_libregnum_render_ctx_load_game (CmacsLibregnumRenderCtx *r,
                                      const char *so_path, char **error_msg)
{
  GError           *error = NULL;
  LrgLoadedGame    *loaded;
  LrgGameTemplate  *game;
  CmacsFboGameHost *host;

  if (!r || !so_path) return FALSE;
  if (r->game_mode) cmacs_libregnum_render_ctx_unload_game (r);

  loaded = lrg_loaded_game_load (so_path, &error);
  if (!loaded)
    {
      if (error_msg)
        *error_msg = g_strdup (error ? error->message : "load failed");
      g_clear_error (&error);
      return FALSE;
    }

  game = lrg_loaded_game_get_game (loaded);
  host = cmacs_fbo_game_host_new (r);

  /* Create the injected input source before startup so the host can expose
   * it (cfgh_get_input_source reads r->game_input). */
  r->game_input = lrg_input_software_new ();
  lrg_input_manager_add_source (lrg_input_manager_get_default (),
                                LRG_INPUT (r->game_input));

  if (!lrg_game_template_startup (game, LRG_GAME_HOST (host), &error))
    {
      if (error_msg)
        *error_msg = g_strdup (error ? error->message : "startup failed");
      g_clear_error (&error);
      lrg_input_manager_remove_source (lrg_input_manager_get_default (),
                                       LRG_INPUT (r->game_input));
      g_clear_object (&r->game_input);
      g_object_unref (host);
      g_object_unref (loaded);
      return FALSE;
    }

  r->loaded_game = loaded;
  r->game        = game;          /* borrowed from loaded_game */
  r->game_host   = LRG_GAME_HOST (host);
  r->game_mode   = TRUE;
  return TRUE;
}

void
cmacs_libregnum_render_ctx_unload_game (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->game_mode) return;

  if (r->game)
    lrg_game_template_shutdown_game (r->game);

  if (r->game_input)
    {
      lrg_input_manager_remove_source (lrg_input_manager_get_default (),
                                       LRG_INPUT (r->game_input));
      g_clear_object (&r->game_input);
    }

  r->game = NULL;                 /* owned by loaded_game */
  g_clear_object (&r->game_host);

  if (r->loaded_game)
    {
      lrg_loaded_game_unload (r->loaded_game);
      g_clear_object (&r->loaded_game);
    }

  r->game_mode = FALSE;
}

gboolean
cmacs_libregnum_render_ctx_is_game (CmacsLibregnumRenderCtx *r)
{
  return r && r->game_mode;
}

/* Whether this view captures all frame mouse events while focused (game) vs
 * only events inside its own window (editor, the default). */
gboolean
cmacs_libregnum_render_ctx_get_mouse_capture_all (CmacsLibregnumRenderCtx *r)
{
  return r && r->mouse_capture_all;
}

void
cmacs_libregnum_render_ctx_set_mouse_capture_all (CmacsLibregnumRenderCtx *r,
                                                  gboolean capture)
{
  if (r) r->mouse_capture_all = capture;
}

void
cmacs_libregnum_render_ctx_game_key (CmacsLibregnumRenderCtx *r,
                                     int grl_key, int press)
{
  if (!r || !r->game_input) return;
  if (press)
    lrg_input_software_press_key (r->game_input, (GrlKey) grl_key);
  else
    lrg_input_software_release_key (r->game_input, (GrlKey) grl_key);
}

void
cmacs_libregnum_render_ctx_game_mouse_move (CmacsLibregnumRenderCtx *r,
                                            double x, double y)
{
  if (!r || !r->game_input) return;
  lrg_input_software_move_mouse_to (r->game_input, (gfloat) x, (gfloat) y);
}

void
cmacs_libregnum_render_ctx_game_mouse_button (CmacsLibregnumRenderCtx *r,
                                              int button, int press)
{
  if (!r || !r->game_input) return;
  if (press)
    lrg_input_software_press_mouse_button (r->game_input,
                                           (GrlMouseButton) button);
  else
    lrg_input_software_release_mouse_button (r->game_input,
                                             (GrlMouseButton) button);
}

/* Render one frame into the FBO and copy the result into DST.
 * DST is BGRA (cairo ARGB32 in memory) pre-allocated to w*h*4.
 *
 * The colour data lands in DST bottom-up (glReadPixels' origin is the
 * lower-left corner); the overlay paint hook flips it for free with a
 * cairo matrix, so there is no CPU row-flip or channel-swap here. */
#ifdef LRG_BUILD_EDITOR
static void cmacs_editor_draw_gizmo (CmacsLibregnumRenderCtx *r);
static gint cmacs_editor_id_for_node (CmacsLibregnumRenderCtx *r,
                                      LrgNode *node);
/* Feature 1 helpers defined after the render loop (see below). */
static gboolean ctx_ensure_lighting_shader (CmacsLibregnumRenderCtx *r);
static void     ctx_push_lights_to_shader  (CmacsLibregnumRenderCtx *r);
static void     ctx_attach_shading_materials (CmacsLibregnumRenderCtx *r,
                                              gboolean on);
#endif
gboolean
cmacs_libregnum_render_ctx_render_to_bgra (CmacsLibregnumRenderCtx *r,
                                           unsigned char *dst,
                                           int dst_w, int dst_h)
{
  if (!r || !r->fbo_valid || !dst) return FALSE;
  if (dst_w != r->width || dst_h != r->height) return FALSE;

  /* Game-module mode: drive the loaded game's update + render into the FBO,
   * sourcing the frame delta and the render-target bracket from the
   * LrgGameHost. The readback stays inside BeginTextureMode/EndTextureMode. */
  if (r->game_mode && r->game && r->game_host)
    {
      gdouble dt = lrg_game_host_get_frame_delta (r->game_host);

      if (r->game_input)
        lrg_input_software_update (r->game_input);
      lrg_game_template_update (r->game, dt);

      lrg_game_host_begin_frame (r->game_host);   /* BeginTextureMode(fbo) */
      ClearBackground ((Color){ 0, 0, 0, 255 });
      lrg_game_template_render (r->game);
      glReadPixels (0, 0, r->width, r->height,
                    GL_BGRA, GL_UNSIGNED_BYTE, dst);
      lrg_game_host_end_frame (r->game_host);     /* EndTextureMode */
      return TRUE;
    }

  /* Advance the camera focus tween (if any) before drawing this
   * frame; the view re-requests a redraw while focus_active is true. */
  ctx_step_focus (r);

  /* NOTE: we deliberately do NOT call lrg_window_begin_frame /
   * end_frame here.  Those wrap raylib's BeginDrawing/EndDrawing, and
   * EndDrawing presents + paces the *hidden* offscreen window:
   * glfwSwapBuffers (vsync-blocks), WaitTime (enforces the window's
   * 60 FPS SetTargetFPS cap -- ~16 ms of sleep per call), and
   * glfwPollEvents.  For an FBO-only readback path that never shows a
   * window, all three are pure latency -- the WaitTime cap alone was
   * throttling every scene update to <=60 FPS and adding up to a frame
   * of sleep to each interactive redraw.  Offscreen rendering needs
   * only BeginTextureMode/EndTextureMode + a current GL context; the
   * default render batch is initialised by InitWindow and flushed by
   * EndTextureMode, so no BeginDrawing is required. */
  BeginTextureMode (r->fbo);
  {
    Color bg = (Color){ 16, 16, 21, 255 };
    ClearBackground (bg);
    if (r->camera)
      {
        lrg_renderer_begin_frame (r->renderer);
        lrg_renderer_begin_layer (r->renderer, LRG_RENDER_LAYER_WORLD);
        /* Persistent background model (e.g. the gnuseye Earth sphere):
         * drawn first, behind the per-tick scene drawables, with an
         * optional spin about +Y.  Depth-tested so surface markers
         * occlude correctly against the far limb. */
        if (r->background_model)
          {
            g_autoptr (GrlVector3) bpos  = grl_vector3_new (0.0f, 0.0f, 0.0f);
            g_autoptr (GrlVector3) baxis = grl_vector3_new (0.0f, 1.0f, 0.0f);
            g_autoptr (GrlVector3) bscl  = grl_vector3_new (1.0f, 1.0f, 1.0f);
            g_autoptr (GrlColor)   bwhite = grl_color_new (255, 255, 255, 255);
            grl_model_draw_ex (r->background_model, bpos, baxis,
                               r->background_spin_deg, bscl, bwhite);
          }
        /* Persistent static overlay (coastlines etc.), behind markers. */
        for (guint i = 0;
             r->static_drawables && i < r->static_drawables->len; i++)
          {
            gpointer d = g_ptr_array_index (r->static_drawables, i);
            if (LRG_IS_DRAWABLE (d))
              lrg_drawable_draw (LRG_DRAWABLE (d), 0.0f);
          }
        for (guint i = 0; r->drawables && i < r->drawables->len; i++)
          {
            gpointer d = g_ptr_array_index (r->drawables, i);
            if (LRG_IS_DRAWABLE (d))
              lrg_drawable_draw (LRG_DRAWABLE (d), 0.0f);
          }
        /* Camera-facing billboards (country flags), only once zoomed in. */
        if (r->billboards && r->billboards->len > 0)
          {
            Camera3D bcam = ctx_raylib_camera (r);
            double cdist = sqrt (bcam.position.x*bcam.position.x
                                 + bcam.position.y*bcam.position.y
                                 + bcam.position.z*bcam.position.z);
            if (cdist < 13.0)
              {
                Color bw = (Color){ 255, 255, 255, 255 };
                for (guint i = 0; i < r->billboards->len; i++)
                  {
                    CmacsBillboard *bb =
                      &g_array_index (r->billboards, CmacsBillboard, i);
                    if (!bb->tex) continue;
                    /* Skip flags on the far side of the globe. */
                    if (!ctx_point_near_side (r, bb->x, bb->y, bb->z))
                      continue;
                    Texture2D *t = grl_texture_get_handle (bb->tex);
                    if (t && t->id)
                      {
                        /* Scale to the zoom so the flag keeps a roughly
                         * constant on-screen size (world size grows with
                         * distance from the camera to the near surface). */
                        double near = cdist - r->occluder_radius;
                        if (near < 0.6) near = 0.6;
                        float esize = bb->size * (float) near;
                        DrawBillboard (bcam, *t,
                                       (Vector3){ bb->x, bb->y, bb->z },
                                       esize, bw);
                      }
                  }
              }
          }
#ifdef LRG_BUILD_EDITOR
        /* Feature 1: shading — push lights to the shader once per frame
         * before drawing any mesh-asset models.  This is a no-op when
         * shading is OFF (lighting_shader is NULL). */
        if (r->shading)
          ctx_push_lights_to_shader (r);

        /* Draw any baked mesh-asset models (glTF/OBJ), positioned + rotated
         * (about Y) + scaled per node.  57.2958 = 180/pi (radians -> degrees).
         *
         * Feature 3: per-node wireframe.  If the node's "wireframe" visual
         * param > 0.5, draw via grl_model_draw_wires_ex instead. */
        for (guint mi = 0; r->editor_models && mi < r->editor_models->len; mi++)
          {
            CmacsEditorModel *em =
              &g_array_index (r->editor_models, CmacsEditorModel, mi);
            g_autoptr (GrlVector3) mpos  = grl_vector3_new (em->x, em->y, em->z);
            g_autoptr (GrlVector3) maxis = grl_vector3_new (0.0f, 1.0f, 0.0f);
            g_autoptr (GrlVector3) mscl  = grl_vector3_new (em->sx, em->sy,
                                                            em->sz);
            g_autoptr (GrlColor)   mtint = grl_color_new (em->cr, em->cg,
                                                          em->cb, 255);
            if (em->model)
              {
                /* Determine wireframe mode from the node's visual param. */
                gboolean wireframe = FALSE;
                if (em->node_id >= 0 && r->editor_node_map
                    && (guint) em->node_id < r->editor_node_map->len)
                  {
                    LrgNode       *wn  = g_ptr_array_index (r->editor_node_map,
                                                            em->node_id);
                    LrgNodeVisual *wv  = wn ? lrg_node_get_visual (wn) : NULL;
                    if (wv)
                      wireframe = lrg_node_visual_get_param_double
                                    (wv, "wireframe", 0.0) > 0.5;
                  }
                if (wireframe)
                  grl_model_draw_wires_ex (em->model, mpos, maxis,
                                           em->ry * 57.2957795f, mscl, mtint);
                else
                  grl_model_draw_ex (em->model, mpos, maxis,
                                     em->ry * 57.2957795f, mscl, mtint);
              }
            else if (em->texture && em->tiles)
              {
                /* Tilemap: draw each non-empty cell as a textured quad on the
                 * ground, sampling the tileset sub-rect for its tile index.
                 * Culling off: the ground-facing winding would otherwise be a
                 * back face from the orbit camera. */
                {
                    float ox = em->x - em->mw * 0.5f;
                    float oz = em->z - em->mh * 0.5f;
                    int cx, cy;
                    g_autoptr (GrlVector3) taxis = grl_vector3_new (0, 1, 0);
                    g_autoptr (GrlVector3) tscl  = grl_vector3_new (1, 1, 1);
                    g_autoptr (GrlColor) twhite  = grl_color_new (255, 255,
                                                                  255, 255);
                    for (cy = 0; cy < em->mh; cy++)
                      for (cx = 0; cx < em->mw; cx++)
                        {
                          int idx = cy * em->mw + cx;
                          gint tile = em->tiles[idx];
                          Vector3 cpos;
                          GrlModel *tm = NULL;
                          Color col = { 200, 200, 200, 255 };
                          if (tile < 0) continue;
                          cpos = (Vector3){ ox + cx + 0.5f, em->y,
                                            oz + cy + 0.5f };
                          if (em->tile_models)
                            tm = g_hash_table_lookup (em->tile_models,
                                                      GINT_TO_POINTER (tile));
                          if (tm)
                            {
                              /* Real tileset art: textured unit-plane model. */
                              g_autoptr (GrlVector3) p =
                                grl_vector3_new (cpos.x, cpos.y, cpos.z);
                              grl_model_draw_ex (tm, p, taxis, 0.0f, tscl,
                                                 twhite);
                            }
                          else
                            {
                              /* Fallback: colour-sampled cell. */
                              if (em->tile_rgb)
                                {
                                  col.r = em->tile_rgb[3 * idx];
                                  col.g = em->tile_rgb[3 * idx + 1];
                                  col.b = em->tile_rgb[3 * idx + 2];
                                }
                              DrawCube (cpos, 0.95f, 0.1f, 0.95f, col);
                              DrawCubeWires (cpos, 0.95f, 0.1f, 0.95f,
                                             (Color){ 40, 40, 40, 255 });
                            }
                        }
                  }
              }
            else if (em->texture && em->flat)
              {
                /* Flat textured quad (legacy / un-configured tilemap). */
                Texture2D *t = grl_texture_get_handle (em->texture);
                if (t)
                  {
                    float hxq = em->sx, hzq = em->sz, yq = em->y;
                    rlDisableBackfaceCulling ();
                    rlSetTexture (t->id);
                    rlBegin (RL_QUADS);
                    rlColor4ub (255, 255, 255, 255);
                    rlTexCoord2f (0.0f, 0.0f);
                    rlVertex3f (em->x - hxq, yq, em->z - hzq);
                    rlTexCoord2f (1.0f, 0.0f);
                    rlVertex3f (em->x + hxq, yq, em->z - hzq);
                    rlTexCoord2f (1.0f, 1.0f);
                    rlVertex3f (em->x + hxq, yq, em->z + hzq);
                    rlTexCoord2f (0.0f, 1.0f);
                    rlVertex3f (em->x - hxq, yq, em->z + hzq);
                    rlEnd ();
                    rlSetTexture (0);
                    rlEnableBackfaceCulling ();
                  }
              }
            else if (em->texture)
              {
                /* Sprite: a camera-facing billboard at the node. */
                Camera3D bcam = ctx_raylib_camera (r);
                Texture2D *t = grl_texture_get_handle (em->texture);
                if (t)
                  DrawBillboard (bcam, *t,
                                 (Vector3){ em->x, em->y, em->z },
                                 fmaxf (em->sx, em->sy),
                                 (Color){ em->cr, em->cg, em->cb, 255 });
              }
          }
        /* Light/audio range spheres + camera frustum, read live from each
         * node's visual params so they reflect the authored values. */
        if (r->editor && r->editor_node_map && r->nodes)
          {
            guint li;
            for (li = 0; li < r->editor_node_map->len
                         && li < r->nodes->len; li++)
              {
                LrgNode          *ln = g_ptr_array_index (r->editor_node_map, li);
                LrgNodeVisual    *lv = ln ? lrg_node_get_visual (ln) : NULL;
                LrgNodeVisualKind lk = lv ? lrg_node_visual_get_kind (lv)
                                          : LRG_NODE_VISUAL_NONE;
                CmacsNode        *nn = &g_array_index (r->nodes, CmacsNode, li);
                Vector3           p = (Vector3){ nn->x, nn->y, nn->z };
                if (lk == LRG_NODE_VISUAL_LIGHT)
                  {
                    float rng = (float)
                      lrg_node_visual_get_param_double (lv, "range", 4.0);
                    /* Optional "intensity" param scales the sphere radius
                     * and the alpha of the gizmo color so authored
                     * intensity changes are visible while editing. */
                    float intensity = (float)
                      lrg_node_visual_get_param_double (lv, "intensity", 1.0);
                    if (intensity < 0.0f) intensity = 0.0f;
                    if (intensity > 8.0f) intensity = 8.0f;
                    float viz_rng = rng * (intensity > 0.0f
                                          ? fmaxf (0.25f, intensity) : 0.25f);
                    guint8 viz_a = (guint8)(int)
                      fminf (255.0f, 60.0f + intensity * 30.0f);
                    Color lc = {
                      (guint8)(int) lrg_node_visual_get_param_double (lv, "r", 250.0),
                      (guint8)(int) lrg_node_visual_get_param_double (lv, "g", 240.0),
                      (guint8)(int) lrg_node_visual_get_param_double (lv, "b", 140.0),
                      viz_a };
                    DrawSphereWires (p, viz_rng, 6, 8, lc);
                  }
                else if (lk == LRG_NODE_VISUAL_AUDIO_EMITTER)
                  {
                    float rng = (float)
                      lrg_node_visual_get_param_double (lv, "range", 4.0);
                    DrawSphereWires (p, rng, 6, 8,
                                     (Color){ 120, 200, 230, 120 });
                  }
                else if (lk == LRG_NODE_VISUAL_CAMERA)
                  {
                    g_autoptr (GrlVector3) rot = lrg_node_get_rotation (ln);
                    float ry  = rot ? rot->y : 0.0f;
                    float fov = (float)
                      lrg_node_visual_get_param_double (lv, "fov", 50.0);
                    float len  = 2.5f;
                    float half = tanf (fov * 0.5f * 0.01745329f) * len;
                    Vector3 fwd = (Vector3){ -sinf (ry), 0.0f, -cosf (ry) };
                    Vector3 rgt = (Vector3){  cosf (ry), 0.0f, -sinf (ry) };
                    Vector3 ctr = (Vector3){ p.x + fwd.x * len, p.y,
                                             p.z + fwd.z * len };
                    Vector3 c[4];
                    Color   fc = (Color){ 200, 160, 240, 200 };
                    int     ci;
                    c[0] = (Vector3){ ctr.x + rgt.x * half, ctr.y + half,
                                      ctr.z + rgt.z * half };
                    c[1] = (Vector3){ ctr.x - rgt.x * half, ctr.y + half,
                                      ctr.z - rgt.z * half };
                    c[2] = (Vector3){ ctr.x - rgt.x * half, ctr.y - half,
                                      ctr.z - rgt.z * half };
                    c[3] = (Vector3){ ctr.x + rgt.x * half, ctr.y - half,
                                      ctr.z + rgt.z * half };
                    for (ci = 0; ci < 4; ci++)
                      {
                        DrawLine3D (p, c[ci], fc);             /* apex edges */
                        DrawLine3D (c[ci], c[(ci + 1) % 4], fc); /* far rect */
                      }
                  }
              }
          }
#endif
        /* Selection highlight: wireframe boxes around selected nodes.
         * In editor mode, draw ALL nodes in the multi-selection (dimmer
         * color), plus a bright box around the primary (r->selected).
         * Outside the editor use the single-select path. */
#ifdef LRG_BUILD_EDITOR
        if (r->editor && r->nodes)
          {
            LrgEditorSelection *esel =
              lrg_editor_get_selection (r->editor);
            GPtrArray *snodes =
              lrg_editor_selection_get_nodes (esel);
            if (snodes && snodes->len > 0)
              {
                guint si;
                for (si = 0; si < snodes->len; si++)
                  {
                    LrgNode *sn =
                      (LrgNode *) g_ptr_array_index (snodes, si);
                    gint sid = cmacs_editor_id_for_node (r, sn);
                    if (sid < 0 || (guint) sid >= r->nodes->len)
                      continue;
                    CmacsNode *cn = &g_array_index (r->nodes, CmacsNode,
                                                    (guint) sid);
                    Vector3 cv = (Vector3){ cn->x, cn->y, cn->z };
                    /* Primary = bright yellow; others = pale cyan. */
                    Color wc = (sid == r->selected)
                               ? (Color){ 255, 235, 120, 255 }
                               : (Color){ 130, 220, 245, 180 };
                    DrawCubeWires (cv,
                                   cn->hw * 2 + 0.35f,
                                   cn->hh * 2 + 0.35f,
                                   cn->hd * 2 + 0.35f, wc);
                  }
              }
            else if (r->selected >= 0
                     && (guint) r->selected < r->nodes->len)
              {
                /* Fallback: selection set empty but r->selected is set
                 * (non-editor pick or pre-rebuild state). */
                CmacsNode *n = &g_array_index (r->nodes, CmacsNode,
                                               (guint) r->selected);
                Vector3 c = (Vector3){ n->x, n->y, n->z };
                DrawCubeWires (c, n->hw * 2 + 0.35f,
                               n->hh * 2 + 0.35f,
                               n->hd * 2 + 0.35f,
                               (Color){ 255, 235, 120, 255 });
              }
          }
        else
#endif
        if (r->selected >= 0 && r->nodes
            && (guint) r->selected < r->nodes->len)
          {
            CmacsNode *n = &g_array_index (r->nodes, CmacsNode,
                                           (guint) r->selected);
            Vector3 c = (Vector3){ n->x, n->y, n->z };
            DrawCubeWires (c, n->hw * 2 + 0.35f, n->hh * 2 + 0.35f,
                           n->hd * 2 + 0.35f, (Color){ 255, 235, 120, 255 });
          }
#ifdef LRG_BUILD_EDITOR
        /* Transform gizmo handles over the selection (translate/rotate/scale). */
        cmacs_editor_draw_gizmo (r);
#endif
        lrg_renderer_end_layer (r->renderer);
        lrg_renderer_end_frame (r->renderer);
      }

    /* Read the FBO colour attachment back while it is still bound.
     * GL_BGRA + GL_UNSIGNED_BYTE matches cairo's ARGB32 byte order on
     * little-endian, so the driver writes straight into DST with no
     * channel-swap loop and no per-frame allocation.  Row stride is
     * width*4, a multiple of the default GL_PACK_ALIGNMENT (4). */
    glReadPixels (0, 0, r->width, r->height,
                  GL_BGRA, GL_UNSIGNED_BYTE, dst);
  }
  EndTextureMode ();

  return TRUE;
}

#include <math.h>

void
cmacs_libregnum_render_ctx_orbit_camera (CmacsLibregnumRenderCtx *r,
                                         double dx_px, double dy_px)
{
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
#ifdef LRG_BUILD_EDITOR
  if (r->camera_lookthrough) return; /* suppressed during look-through */
#endif
  r->focusing = FALSE;   /* manual control cancels an in-flight focus */
  LrgCamera3D *c3 = LRG_CAMERA3D (r->camera);
  g_autoptr (GrlVector3) pos = lrg_camera3d_get_position (c3);
  g_autoptr (GrlVector3) tgt = lrg_camera3d_get_target   (c3);
  double ox = pos->x - tgt->x, oy = pos->y - tgt->y, oz = pos->z - tgt->z;
  double rad = sqrt (ox*ox + oy*oy + oz*oz);
  if (rad < 1e-3) rad = 1e-3;
  double yaw   = atan2 (ox, oz);
  double pitch = asin  (oy / rad);
  yaw   -= dx_px * 0.005;
  pitch += dy_px * 0.005;
  if (pitch >  1.4) pitch =  1.4;
  if (pitch < -1.4) pitch = -1.4;
  double nx = rad * cos (pitch) * sin (yaw);
  double ny = rad * sin (pitch);
  double nz = rad * cos (pitch) * cos (yaw);
  lrg_camera3d_set_position_xyz (c3,
                                  tgt->x + (float) nx,
                                  tgt->y + (float) ny,
                                  tgt->z + (float) nz);
}

void
cmacs_libregnum_render_ctx_zoom_camera (CmacsLibregnumRenderCtx *r,
                                        double wheel_dy)
{
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
#ifdef LRG_BUILD_EDITOR
  if (r->camera_lookthrough) return;
#endif
  r->focusing = FALSE;
  LrgCamera3D *c3 = LRG_CAMERA3D (r->camera);
  g_autoptr (GrlVector3) pos = lrg_camera3d_get_position (c3);
  g_autoptr (GrlVector3) tgt = lrg_camera3d_get_target   (c3);
  double ox = pos->x - tgt->x, oy = pos->y - tgt->y, oz = pos->z - tgt->z;
  double scale = pow (0.9, wheel_dy);
  ox *= scale; oy *= scale; oz *= scale;
  lrg_camera3d_set_position_xyz (c3,
                                  tgt->x + (float) ox,
                                  tgt->y + (float) oy,
                                  tgt->z + (float) oz);
}

/* Pan the camera: slide both position and target across the screen
 * plane so the scene tracks the drag (right-drag).  DX_PX/DY_PX are
 * pointer deltas in pixels; the world distance is scaled by the
 * camera-to-target distance so panning feels consistent at any zoom. */
void
cmacs_libregnum_render_ctx_pan_camera (CmacsLibregnumRenderCtx *r,
                                       double dx_px, double dy_px)
{
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
#ifdef LRG_BUILD_EDITOR
  if (r->camera_lookthrough) return;
#endif
  r->focusing = FALSE;
  LrgCamera3D *c3 = LRG_CAMERA3D (r->camera);
  g_autoptr (GrlVector3) pos = lrg_camera3d_get_position (c3);
  g_autoptr (GrlVector3) tgt = lrg_camera3d_get_target   (c3);
  g_autoptr (GrlVector3) up  = lrg_camera3d_get_up       (c3);

  double fx = tgt->x - pos->x, fy = tgt->y - pos->y, fz = tgt->z - pos->z;
  double dist = sqrt (fx*fx + fy*fy + fz*fz);
  if (dist < 1e-3) dist = 1e-3;
  fx /= dist; fy /= dist; fz /= dist;
  double ux = up ? up->x : 0.0, uy = up ? up->y : 1.0, uz = up ? up->z : 0.0;
  /* right = forward x up */
  double rx = fy*uz - fz*uy, ry = fz*ux - fx*uz, rz = fx*uy - fy*ux;
  double rl = sqrt (rx*rx + ry*ry + rz*rz);
  if (rl < 1e-6) rl = 1e-6;
  rx /= rl; ry /= rl; rz /= rl;
  /* camera-up = right x forward */
  double cux = ry*fz - rz*fy, cuy = rz*fx - rx*fz, cuz = rx*fy - ry*fx;

  double s = dist * 0.0015;
  /* Drag right -> scene moves right (camera moves -right); drag down
   * (dy_px > 0) -> scene moves down (camera moves +up). */
  double mx = (-dx_px) * rx * s + dy_px * cux * s;
  double my = (-dx_px) * ry * s + dy_px * cuy * s;
  double mz = (-dx_px) * rz * s + dy_px * cuz * s;
  lrg_camera3d_set_position_xyz (c3, (float)(pos->x + mx),
                                 (float)(pos->y + my), (float)(pos->z + mz));
  lrg_camera3d_set_target_xyz   (c3, (float)(tgt->x + mx),
                                 (float)(tgt->y + my), (float)(tgt->z + mz));
}

void
cmacs_libregnum_render_ctx_get_camera_state (CmacsLibregnumRenderCtx *r,
                                              double *px, double *py,
                                              double *pz,
                                              double *tx, double *ty,
                                              double *tz,
                                              double *fov)
{
  if (px) *px = 0;
  if (py) *py = 0;
  if (pz) *pz = 0;
  if (tx) *tx = 0;
  if (ty) *ty = 0;
  if (tz) *tz = 0;
  if (fov) *fov = 0;
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
  LrgCamera3D *c3 = LRG_CAMERA3D (r->camera);
  g_autoptr (GrlVector3) pos = lrg_camera3d_get_position (c3);
  g_autoptr (GrlVector3) tgt = lrg_camera3d_get_target   (c3);
  if (px && pos) *px = pos->x;
  if (py && pos) *py = pos->y;
  if (pz && pos) *pz = pos->z;
  if (tx && tgt) *tx = tgt->x;
  if (ty && tgt) *ty = tgt->y;
  if (tz && tgt) *tz = tgt->z;
  if (fov) *fov = lrg_camera3d_get_fovy (c3);
}

void
cmacs_libregnum_render_ctx_set_camera_state (CmacsLibregnumRenderCtx *r,
                                              double px, double py,
                                              double pz,
                                              double tx, double ty,
                                              double tz,
                                              double fov)
{
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
  LrgCamera3D *c3 = LRG_CAMERA3D (r->camera);
  lrg_camera3d_set_position_xyz (c3, (float) px, (float) py, (float) pz);
  lrg_camera3d_set_target_xyz   (c3, (float) tx, (float) ty, (float) tz);
  if (fov > 0.0)
    lrg_camera3d_set_fovy (c3, (float) fov);
}

/* Render the current frame synchronously and write it to PATH as a PNG.
 * Used for headless/automated render verification (no compositor capture). */
gboolean
cmacs_libregnum_render_ctx_snapshot_png (CmacsLibregnumRenderCtx *r,
                                         const char *path, char **error_msg)
{
  unsigned char   *buf;
  cairo_surface_t *surface;
  cairo_status_t   st;

  if (!r || !path)
    {
      if (error_msg) *error_msg = g_strdup ("snapshot: invalid arguments");
      return FALSE;
    }
  if (r->width <= 0 || r->height <= 0)
    {
      if (error_msg) *error_msg = g_strdup ("snapshot: view has no size");
      return FALSE;
    }

  buf = g_malloc0 ((gsize) r->width * (gsize) r->height * 4);
  if (!cmacs_libregnum_render_ctx_render_to_bgra (r, buf, r->width, r->height))
    {
      g_free (buf);
      if (error_msg) *error_msg = g_strdup ("snapshot: render failed");
      return FALSE;
    }

  /* The readback is BGRA which, on little-endian, is cairo's ARGB32 byte
   * order, so the buffer feeds cairo directly (orientation may be GL
   * bottom-up; immaterial for verification). */
  surface = cairo_image_surface_create_for_data (buf, CAIRO_FORMAT_ARGB32,
                                                 r->width, r->height,
                                                 r->width * 4);
  st = cairo_surface_write_to_png (surface, path);
  cairo_surface_destroy (surface);
  g_free (buf);

  if (st != CAIRO_STATUS_SUCCESS)
    {
      if (error_msg)
        *error_msg = g_strdup (cairo_status_to_string (st));
      return FALSE;
    }
  return TRUE;
}

/* ── Editor / level authoring ──────────────────────────────────────
 * Drive an engine LrgEditor and bake its level into the scene drawables
 * so it renders through the normal scene path and reuses the node model
 * (picking, labels, cmacs-libregnum-tree-nodes) for the outliner. */
#ifdef LRG_BUILD_EDITOR

/* ── Feature: real-time scene shading (Feature 1) ───────────────────
 *
 * Blinn-Phong lighting shader embedded as C string literals.  The GLSL
 * source comes from:
 *   deps/libregnum/deps/graylib/deps/raylib/examples/shaders/
 *       resources/shaders/glsl330/lighting.vs + lighting.fs
 *
 * The vertex shader passes world-space position, normal and the tint
 * colour to the fragment shader.  The fragment shader accumulates
 * contributions from up to 4 lights[] and adds an ambient term.
 *
 * Uniform names used (raylib/rlights convention, must match exactly):
 *   matModel  mat4  -- model matrix (sent by DrawMesh/grl_model_draw_ex)
 *   matNormal mat4  -- normal matrix (sent by DrawMesh)
 *   mvp       mat4  -- model-view-projection (sent by DrawMesh)
 *   viewPos   vec3  -- camera world position (set per-frame below)
 *   ambient   vec4  -- ambient colour (set once)
 *   lights[i].enabled    int
 *   lights[i].type       int  (0=directional, 1=point)
 *   lights[i].position   vec3
 *   lights[i].target     vec3
 *   lights[i].color      vec4
 */
static const char *s_lighting_vs =
  "#version 330\n"
  "in vec3 vertexPosition;\n"
  "in vec2 vertexTexCoord;\n"
  "in vec3 vertexNormal;\n"
  "in vec4 vertexColor;\n"
  "uniform mat4 mvp;\n"
  "uniform mat4 matModel;\n"
  "uniform mat4 matNormal;\n"
  "out vec3 fragPosition;\n"
  "out vec2 fragTexCoord;\n"
  "out vec4 fragColor;\n"
  "out vec3 fragNormal;\n"
  "void main() {\n"
  "    fragPosition = vec3(matModel*vec4(vertexPosition, 1.0));\n"
  "    fragTexCoord = vertexTexCoord;\n"
  "    fragColor    = vertexColor;\n"
  "    fragNormal   = normalize(vec3(matNormal*vec4(vertexNormal, 1.0)));\n"
  "    gl_Position  = mvp*vec4(vertexPosition, 1.0);\n"
  "}\n";

static const char *s_lighting_fs =
  "#version 330\n"
  "in vec3 fragPosition;\n"
  "in vec2 fragTexCoord;\n"
  "in vec4 fragColor;\n"
  "in vec3 fragNormal;\n"
  "uniform sampler2D texture0;\n"
  "uniform vec4 colDiffuse;\n"
  "out vec4 finalColor;\n"
  "#define MAX_LIGHTS 4\n"
  "#define LIGHT_DIRECTIONAL 0\n"
  "#define LIGHT_POINT 1\n"
  "struct Light {\n"
  "    int enabled;\n"
  "    int type;\n"
  "    vec3 position;\n"
  "    vec3 target;\n"
  "    vec4 color;\n"
  "};\n"
  "uniform Light lights[MAX_LIGHTS];\n"
  "uniform vec4 ambient;\n"
  "uniform vec3 viewPos;\n"
  "void main() {\n"
  "    vec4 texelColor = texture(texture0, fragTexCoord);\n"
  "    vec3 base   = (texelColor*colDiffuse*fragColor).rgb;\n"
  "    vec3 normal = normalize(fragNormal);\n"
  "    vec3 viewD  = normalize(viewPos - fragPosition);\n"
  "    vec3 light_accum = ambient.rgb;\n"
  "    vec3 specular    = vec3(0.0);\n"
  "    for (int i = 0; i < MAX_LIGHTS; i++) {\n"
  "        if (lights[i].enabled == 1) {\n"
  "            vec3 L;\n"
  "            if (lights[i].type == LIGHT_DIRECTIONAL)\n"
  "                L = normalize(lights[i].position - lights[i].target);\n"
  "            else\n"
  "                L = normalize(lights[i].position - fragPosition);\n"
  "            /* Two-sided diffuse: an editor preview must light the faces the\n"
  "             * user sees regardless of an imported mesh's normal winding. */\n"
  "            float NdotL = abs(dot(normal, L));\n"
  "            light_accum += lights[i].color.rgb*NdotL;\n"
  "            float specCo = pow(max(0.0, dot(viewD, reflect(-L, normal))), 16.0);\n"
  "            specular += lights[i].color.rgb*specCo*0.3;\n"
  "        }\n"
  "    }\n"
  "    vec3 c = base*light_accum + specular;\n"
  "    finalColor = vec4(min(c, vec3(1.0)), 1.0);\n"
  "}\n";

/* Lazily create the lighting shader + a GrlMaterial that binds it.
 * Returns TRUE if the shader is ready (created or already existed).
 * Must be called from within an active GL context (inside the render
 * loop, i.e. between BeginTextureMode and EndTextureMode). */
static gboolean
ctx_ensure_lighting_shader (CmacsLibregnumRenderCtx *r)
{
  GError *err = NULL;
  if (r->lighting_shader && r->lighting_material)
    return TRUE;
  g_clear_object (&r->lighting_shader);
  g_clear_object (&r->lighting_material);
  r->lighting_shader = grl_shader_new_from_memory (s_lighting_vs,
                                                   s_lighting_fs,
                                                   &err);
  if (!r->lighting_shader)
    {
      g_warning ("cmacs-libregnum: lighting shader compile failed: %s",
                 err ? err->message : "(unknown)");
      g_clear_error (&err);
      return FALSE;
    }
  r->lighting_material = grl_material_new_default ();
  if (!r->lighting_material)
    {
      g_warning ("cmacs-libregnum: failed to create lighting material");
      g_clear_object (&r->lighting_shader);
      return FALSE;
    }
  grl_material_set_shader (r->lighting_material, r->lighting_shader);
  /* Set a soft warm ambient once (can be overridden by Lisp in the future). */
  {
    gint loc = grl_shader_get_location (r->lighting_shader, "ambient");
    if (loc >= 0)
      grl_shader_set_value_vec4 (r->lighting_shader, loc,
                                 0.25f, 0.25f, 0.25f, 1.0f);
  }
  return TRUE;
}

/* Push up to 4 LIGHT nodes from the current scene to the lighting shader,
 * and set the viewPos uniform.  Call just before drawing lit models.
 *
 * Light layout in the shader: lights[0..3] with sub-fields
 *   lights[i].enabled, lights[i].type, lights[i].position, lights[i].color
 * We use LIGHT_POINT (type=1) for all point lights.
 * Format strings for location lookup must match the fragment shader exactly. */
static void
ctx_push_lights_to_shader (CmacsLibregnumRenderCtx *r)
{
  /* raw Shader* from the GrlShader wrapper */
  Shader *sh;
  Camera3D cam;
  int light_count = 0;
  int i;
  char name_buf[64];
  int loc;

  if (!r->lighting_shader) return;
  sh = (Shader *) grl_shader_get_handle (r->lighting_shader);
  if (!sh) return;

  /* Camera world position -> viewPos. */
  cam = ctx_raylib_camera (r);
  loc = GetShaderLocation (*sh, "viewPos");
  if (loc >= 0)
    {
      float vp[3] = { cam.position.x, cam.position.y, cam.position.z };
      SetShaderValue (*sh, loc, vp, SHADER_UNIFORM_VEC3);
    }

  /* Zero all 4 light slots first so stale data does not persist. */
  for (i = 0; i < 4; i++)
    {
      int en = 0;
      g_snprintf (name_buf, sizeof (name_buf), "lights[%d].enabled", i);
      loc = GetShaderLocation (*sh, name_buf);
      if (loc >= 0)
        SetShaderValue (*sh, loc, &en, SHADER_UNIFORM_INT);
    }

  /* Iterate the node map and fill up to 4 LIGHT nodes. */
  if (r->editor_node_map && r->nodes)
    {
      guint li;
      for (li = 0;
           li < r->editor_node_map->len && li < r->nodes->len
             && light_count < 4;
           li++)
        {
          LrgNode       *ln = g_ptr_array_index (r->editor_node_map, li);
          LrgNodeVisual *lv = ln ? lrg_node_get_visual (ln) : NULL;
          LrgNodeVisualKind lk;
          CmacsNode     *nn;
          float pos[3], col[4];
          int en = 1, type = 1;

          if (!lv) continue;
          lk = lrg_node_visual_get_kind (lv);
          if (lk != LRG_NODE_VISUAL_LIGHT) continue;

          nn = &g_array_index (r->nodes, CmacsNode, li);
          pos[0] = nn->x; pos[1] = nn->y; pos[2] = nn->z;
          col[0] = (float) lrg_node_visual_get_param_double (lv, "r", 250.0)
                   / 255.0f;
          col[1] = (float) lrg_node_visual_get_param_double (lv, "g", 240.0)
                   / 255.0f;
          col[2] = (float) lrg_node_visual_get_param_double (lv, "b", 140.0)
                   / 255.0f;
          col[3] = 1.0f;

          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].enabled", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0)
            SetShaderValue (*sh, loc, &en, SHADER_UNIFORM_INT);

          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].type", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0)
            SetShaderValue (*sh, loc, &type, SHADER_UNIFORM_INT);

          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].position", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0)
            SetShaderValue (*sh, loc, pos, SHADER_UNIFORM_VEC3);

          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].color", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0)
            SetShaderValue (*sh, loc, col, SHADER_UNIFORM_VEC4);

          light_count++;
        }
    }
}

/* Attach (or detach) the lighting material on all MESH_ASSET models.
 * Called at bake time when shading is toggled: iterates editor_models,
 * finds those with a GrlModel (the MESH_ASSET entries), and calls
 * grl_model_set_material(model, 0, lighting_material) when on, or
 * grl_model_set_material(model, 0, default_material) when off.
 * Sprite textured-quad models are also shaded (they have normals). */
static void
ctx_attach_shading_materials (CmacsLibregnumRenderCtx *r, gboolean on)
{
  guint mi;
  if (!r->editor_models) return;
  for (mi = 0; mi < r->editor_models->len; mi++)
    {
      CmacsEditorModel *em = &g_array_index (r->editor_models,
                                             CmacsEditorModel, mi);
      if (!em->model) continue;
      if (on && r->lighting_material)
        grl_model_set_material (em->model, 0, r->lighting_material);
      else
        {
          /* Restore a plain default material (no custom shader). */
          GrlMaterial *def = grl_material_new_default ();
          grl_model_set_material (em->model, 0, def);
          g_object_unref (def);
        }
    }
}

/* Build a unit-plane GrlModel textured with TEX (transfer none).  Drawing this
 * via grl_model_draw_ex uses the mesh/VAO path, which -- unlike raylib's rlgl
 * textured immediate mode -- composites correctly inside the editor FBO batch.
 * Returns a new model (transfer full), or NULL. */
static GrlModel *
cmacs_editor_textured_quad (GrlTexture *tex)
{
  GrlMesh  *mesh;
  GrlModel *model;
  if (tex == NULL)
    return NULL;
  mesh = grl_mesh_new_plane (1.0f, 1.0f, 1, 1);
  if (mesh == NULL)
    return NULL;
  model = grl_model_new_from_mesh (mesh);
  g_object_unref (mesh);
  if (model == NULL)
    return NULL;
  grl_model_set_texture (model, 0, GRL_MATERIAL_MAP_ALBEDO, tex);
  return model;
}

/* Bake one level node into a drawable + scene node; recurse over children.
 * Returns nothing; node ids stay in lockstep with editor_node_map. */
static void
cmacs_editor_bake_node (CmacsLibregnumRenderCtx *r, LrgNode *node,
                        int depth, int parent)
{
  GrlVector3       *loc  = lrg_node_get_location (node);
  float             x    = loc ? loc->x : 0.0f;
  float             y    = loc ? loc->y : 0.0f;
  float             z    = loc ? loc->z : 0.0f;
  LrgNodeVisual    *vis  = lrg_node_get_visual (node);
  LrgNodeVisualKind kind = vis ? lrg_node_visual_get_kind (vis)
                               : LRG_NODE_VISUAL_NONE;
  const char       *name = lrg_node_get_name (node);
  LrgShape         *shape = NULL;
  float             hw = 0.5f, hh = 0.5f, hd = 0.5f;  /* AABB half-extents */
  guint8            cr = 170, cg = 170, cb = 180;
  gint              id;
  GPtrArray        *children;
  guint             i;
  GrlVector3       *nrot = lrg_node_get_rotation (node);
  GrlVector3       *nscl = lrg_node_get_scale (node);
  float             rrx = nrot ? nrot->x : 0.0f;
  float             rry = nrot ? nrot->y : 0.0f;
  float             rrz = nrot ? nrot->z : 0.0f;
  float             ssx = nscl ? nscl->x : 1.0f;
  float             ssy = nscl ? nscl->y : 1.0f;
  float             ssz = nscl ? nscl->z : 1.0f;

  switch (kind)
    {
    case LRG_NODE_VISUAL_PRIMITIVE:       cr = 120; cg = 170; cb = 240; break;
    case LRG_NODE_VISUAL_MESH_ASSET:      cr = 160; cg = 220; cb = 160; break;
    case LRG_NODE_VISUAL_SPRITE:          cr = 240; cg = 210; cb = 120; break;
    case LRG_NODE_VISUAL_LIGHT:           cr = 250; cg = 240; cb = 140; break;
    case LRG_NODE_VISUAL_CAMERA:          cr = 200; cg = 160; cb = 240; break;
    case LRG_NODE_VISUAL_AUDIO_EMITTER:   cr = 160; cg = 200; cb = 220; break;
    case LRG_NODE_VISUAL_PREFAB_INSTANCE: cr = 220; cg = 160; cb = 200; break;
    default:                              cr = 170; cg = 170; cb = 180; break;
    }

  /* If the visual has a material, use its color instead of the per-kind
   * default so "Set color" authoring is immediately visible. */
  if (vis)
    {
      LrgMaterial3D *mat = lrg_node_visual_get_material (vis);
      if (mat)
        {
          gfloat mr, mg, mb, ma;
          lrg_material3d_get_color (mat, &mr, &mg, &mb, &ma);
          cr = (guint8)(int)(mr * 255.0f + 0.5f);
          cg = (guint8)(int)(mg * 255.0f + 0.5f);
          cb = (guint8)(int)(mb * 255.0f + 0.5f);
        }
    }

  /* Build the matching drawable + bounding box.  Each primitive maps to its
   * OWN LrgShape3D; MESH_ASSET loads + draws a real model; the other visual
   * kinds get a distinctive gizmo shape.  The AABB half-extents (hw,hh,hd)
   * drive ray-picking + the selection wireframe, so they track the shape. */
  if (kind == LRG_NODE_VISUAL_PRIMITIVE)
    {
      switch (lrg_node_visual_get_primitive (vis))
        {
        case LRG_PRIMITIVE_PLANE:
          shape = LRG_SHAPE (lrg_plane3d_new_at (x, y, z, 1.0f, 1.0f));
          hh = 0.1f;   /* flat in Y: keep a clickable slab */
          break;
        case LRG_PRIMITIVE_CIRCLE:
          shape = LRG_SHAPE (lrg_circle3d_new_at (x, y, z, 0.5f));
          hh = 0.1f;   /* flat disc */
          break;
        case LRG_PRIMITIVE_CIRCLE_2D:
          shape = LRG_SHAPE (lrg_circle3d_new_at (x, y, z, 0.5f));
          hh = 0.05f;  /* 2D circle shown flat in the 3D view */
          break;
        case LRG_PRIMITIVE_RECTANGLE_2D:
          shape = LRG_SHAPE (lrg_cube3d_new_at (x, y, z, 1.0f, 0.05f, 1.0f));
          hh = 0.05f;  /* 2D rectangle shown as a flat slab */
          break;
        case LRG_PRIMITIVE_GRID:
          {
            LrgGrid3D *g = lrg_grid3d_new_sized (10, 0.5f);
            lrg_shape3d_set_position_xyz (LRG_SHAPE3D (g), x, y, z);
            shape = LRG_SHAPE (g);
            hw = 2.5f; hh = 0.1f; hd = 2.5f;
          }
          break;
        case LRG_PRIMITIVE_UV_SPHERE:
          shape = LRG_SHAPE (lrg_sphere3d_new_at (x, y, z, 0.5f));
          break;
        case LRG_PRIMITIVE_ICO_SPHERE:
          shape = LRG_SHAPE (lrg_icosphere3d_new_at (x, y, z, 0.5f));
          break;
        case LRG_PRIMITIVE_CYLINDER:
          shape = LRG_SHAPE (lrg_cylinder3d_new_at (x, y, z, 0.5f, 1.0f));
          break;
        case LRG_PRIMITIVE_CONE:
          shape = LRG_SHAPE (lrg_cone3d_new_at (x, y, z, 0.5f, 1.0f));
          break;
        case LRG_PRIMITIVE_TORUS:
          shape = LRG_SHAPE (lrg_torus3d_new_at (x, y, z, 0.6f, 0.25f));
          hw = 0.85f; hh = 0.25f; hd = 0.85f;
          break;
        case LRG_PRIMITIVE_CUBE:
        default:
          shape = LRG_SHAPE (lrg_cube3d_new_at (x, y, z, 1.0f, 1.0f, 1.0f));
          break;
        }
    }
  else if (kind == LRG_NODE_VISUAL_MESH_ASSET)
    {
      const char *asset = lrg_node_visual_get_asset (vis);
      GrlModel   *model = (asset && asset[0])
                            ? grl_model_new_from_file (asset, NULL) : NULL;
      if (model)
        {
          g_autoptr (GrlBoundingBox) bb = grl_model_get_bounding_box (model);
          CmacsEditorModel em;
          if (bb)
            {
              hw = fmaxf (fabsf (bb->max.x), fabsf (bb->min.x));
              hh = fmaxf (fabsf (bb->max.y), fabsf (bb->min.y));
              hd = fmaxf (fabsf (bb->max.z), fabsf (bb->min.z));
              if (hw < 0.05f) hw = 0.5f;
              if (hh < 0.05f) hh = 0.5f;
              if (hd < 0.05f) hd = 0.5f;
            }
          em.model = model;
          em.texture = NULL;
          em.flat = FALSE;
          em.tiles = NULL;
          em.tile_rgb = NULL; em.tile_models = NULL; em.tile_textures = NULL;
          em.x = x; em.y = y; em.z = z;
          em.rx = rrx; em.ry = rry; em.rz = rrz;
          em.sx = ssx; em.sy = ssy; em.sz = ssz;
          em.cr = 230; em.cg = 230; em.cb = 235;
          em.node_id = (gint) r->nodes->len; /* id add_node will assign */
          if (r->editor_models)
            g_array_append_val (r->editor_models, em);
          else
            g_object_unref (model);
          hw *= fabsf (ssx); hh *= fabsf (ssy); hd *= fabsf (ssz);
        }
      else
        /* Missing/failed asset: a green placeholder cube. */
        shape = LRG_SHAPE (lrg_cube3d_new_at (x, y, z, 1.0f, 1.0f, 1.0f));
    }
  else if (kind == LRG_NODE_VISUAL_SPRITE)
    {
      const char *asset = lrg_node_visual_get_asset (vis);
      GrlTexture *tex = (asset && asset[0])
                          ? grl_texture_new_from_file (asset) : NULL;
      GrlModel *smodel = cmacs_editor_textured_quad (tex);
      if (tex && smodel)
        {
          /* Sprite: a flat textured quad on the ground (real texture, drawn via
           * the working mesh path).  rx tilts it upright if the node is rotated. */
          CmacsEditorModel em;
          em.model = smodel;
          em.texture = tex;         /* kept for cleanup */
          em.flat = FALSE;
          em.tiles = NULL;
          em.tile_rgb = NULL; em.tile_models = NULL; em.tile_textures = NULL;
          em.x = x; em.y = y; em.z = z;
          em.rx = rrx; em.ry = rry; em.rz = rrz;
          em.sx = ssx; em.sy = ssy; em.sz = ssz;
          em.cr = 255; em.cg = 255; em.cb = 255;
          em.node_id = (gint) r->nodes->len; /* id add_node will assign */
          if (r->editor_models)
            g_array_append_val (r->editor_models, em);
          else { g_object_unref (smodel); g_object_unref (tex); }
          hw = 0.5f * fabsf (ssx); hh = 0.5f * fabsf (ssy);
          hd = 0.5f * fabsf (ssz);
        }
      else if (tex)
        {
          g_object_unref (tex);
          shape = LRG_SHAPE (lrg_plane3d_new_at (x, y, z, 1.0f, 1.0f));
          hh = 0.1f;
        }
      else                  /* no/failed image: flat plane gizmo */
        {
          shape = LRG_SHAPE (lrg_plane3d_new_at (x, y, z, 1.0f, 1.0f));
          hh = 0.1f;
        }
    }
  else if (kind == LRG_NODE_VISUAL_TILEMAP)
    {
      /* Render an mw*mh grid of per-cell tiles from the tileset image, reading
       * the tilemap data out of the node's visual params (so it persists in
       * the .rlevel).  With no tileset/dimensions, show a reference grid. */
      const char *asset = lrg_node_visual_get_asset (vis);
      int mw = (int) lrg_node_visual_get_param_double (vis, "mw", 0.0);
      int mh = (int) lrg_node_visual_get_param_double (vis, "mh", 0.0);
      GrlTexture *tex = (asset && asset[0])
                          ? grl_texture_new_from_file (asset) : NULL;
      if (tex && mw > 0 && mh > 0)
        {
          CmacsEditorModel em;
          const GValue *tv = lrg_node_visual_get_param (vis, "tiles");
          int n = mw * mh, i;
          gint *tiles = g_new (gint, n);
          for (i = 0; i < n; i++)
            tiles[i] = -1;
          if (tv != NULL && G_VALUE_HOLDS_STRING (tv))
            {
              const char *csv = g_value_get_string (tv);
              gchar **parts = g_strsplit (csv ? csv : "", ",", -1);
              for (i = 0; parts && parts[i] != NULL && i < n; i++)
                if (parts[i][0] != '\0')
                  tiles[i] = (gint) g_ascii_strtoll (parts[i], NULL, 10);
              g_strfreev (parts);
            }
          else if (tv != NULL && G_VALUE_HOLDS_INT (tv))
            tiles[0] = g_value_get_int (tv);
          else if (tv != NULL && G_VALUE_HOLDS_INT64 (tv))
            tiles[0] = (gint) g_value_get_int64 (tv);
          em.model = NULL; em.texture = tex; em.flat = TRUE; em.tiles = tiles;
          em.mw = mw; em.mh = mh;
          em.tw = (int) lrg_node_visual_get_param_double (vis, "tw", 16.0);
          em.th = (int) lrg_node_visual_get_param_double (vis, "th", 16.0);
          em.cols = (int) lrg_node_visual_get_param_double (vis, "cols", 1.0);
          if (em.cols < 1) em.cols = 1;
          if (em.tw < 1) em.tw = 1;
          if (em.th < 1) em.th = 1;
          /* Sample a representative colour per cell from the tileset image. */
          em.tile_rgb = g_new0 (guint8, 3 * n);
          {
            Image img = LoadImage (asset);
            if (img.data != NULL)
              {
                for (i = 0; i < n; i++)
                  {
                    int tile = tiles[i], col, row, px, py;
                    Color c;
                    if (tile < 0) continue;
                    col = tile % em.cols;
                    row = tile / em.cols;
                    px = col * em.tw + em.tw / 2;
                    py = row * em.th + em.th / 2;
                    if (px >= img.width)  px = img.width - 1;
                    if (py >= img.height) py = img.height - 1;
                    c = GetImageColor (img, px, py);
                    em.tile_rgb[3 * i]     = c.r;
                    em.tile_rgb[3 * i + 1] = c.g;
                    em.tile_rgb[3 * i + 2] = c.b;
                  }
                UnloadImage (img);
              }
          }
          /* Build a textured plane model per distinct tile (real tileset art,
           * drawn via the mesh path that composites in the FBO batch). */
          em.tile_models = g_hash_table_new_full (g_direct_hash, g_direct_equal,
                                                  NULL, g_object_unref);
          em.tile_textures = g_ptr_array_new_with_free_func (g_object_unref);
          {
            GrlImage *isrc = grl_image_new_from_file (asset);
            if (isrc != NULL)
              {
                int iw = grl_image_get_width (isrc);
                int ih = grl_image_get_height (isrc);
                for (i = 0; i < n; i++)
                  {
                    int tile = tiles[i], col, row;
                    g_autoptr (GrlRectangle) rect = NULL;
                    GrlImage *sub;
                    GrlTexture *ttex;
                    GrlModel *tmodel;
                    if (tile < 0
                        || g_hash_table_contains (em.tile_models,
                                                  GINT_TO_POINTER (tile)))
                      continue;
                    col = tile % em.cols;
                    row = tile / em.cols;
                    if (col * em.tw >= iw || row * em.th >= ih)
                      continue;
                    rect = grl_rectangle_new ((float) (col * em.tw),
                                              (float) (row * em.th),
                                              (float) em.tw, (float) em.th);
                    sub = grl_image_from_region (isrc, rect);
                    if (!sub) continue;
                    ttex = grl_texture_new_from_image (sub);
                    g_object_unref (sub);
                    if (!ttex) continue;
                    tmodel = cmacs_editor_textured_quad (ttex);
                    if (tmodel)
                      {
                        g_ptr_array_add (em.tile_textures, ttex);
                        g_hash_table_insert (em.tile_models,
                                             GINT_TO_POINTER (tile), tmodel);
                      }
                    else
                      g_object_unref (ttex);
                  }
                g_object_unref (isrc);
              }
          }
          em.x = x; em.y = y; em.z = z;
          em.rx = rrx; em.ry = rry; em.rz = rrz;
          em.sx = ssx; em.sy = ssy; em.sz = ssz;
          em.cr = 255; em.cg = 255; em.cb = 255;
          em.node_id = (gint) r->nodes->len; /* id add_node will assign */
          if (r->editor_models)
            g_array_append_val (r->editor_models, em);
          else { g_object_unref (tex); g_free (tiles); g_free (em.tile_rgb);
                 g_clear_pointer (&em.tile_models, g_hash_table_destroy);
                 g_clear_pointer (&em.tile_textures, g_ptr_array_unref); }
          hw = (float) mw * 0.5f; hh = 0.1f; hd = (float) mh * 0.5f;
        }
      else
        {
          LrgGrid3D *g;
          if (tex) g_object_unref (tex);
          g = lrg_grid3d_new_sized (16, 0.5f);
          lrg_shape3d_set_position_xyz (LRG_SHAPE3D (g), x, y, z);
          shape = LRG_SHAPE (g);
          hw = 4.0f; hh = 0.1f; hd = 4.0f;
        }
    }
  else if (kind == LRG_NODE_VISUAL_LIGHT)
    {
      shape = LRG_SHAPE (lrg_icosphere3d_new_at (x, y, z, 0.3f));
      hw = 0.3f; hh = 0.3f; hd = 0.3f;
    }
  else if (kind == LRG_NODE_VISUAL_CAMERA)
    {
      shape = LRG_SHAPE (lrg_cone3d_new_at (x, y, z, 0.4f, 0.7f));
      hw = 0.4f; hh = 0.45f; hd = 0.4f;
    }
  else if (kind == LRG_NODE_VISUAL_AUDIO_EMITTER)
    {
      shape = LRG_SHAPE (lrg_sphere3d_new_at (x, y, z, 0.35f));
      hw = 0.35f; hh = 0.35f; hd = 0.35f;
    }
  else if (kind == LRG_NODE_VISUAL_PREFAB_INSTANCE)
    {
      shape = LRG_SHAPE (lrg_cube3d_new_at (x, y, z, 1.0f, 1.0f, 1.0f));
    }

  if (shape)
    {
      g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, 255);
      /* Reflect the node's rotation (radians) + scale so move/rotate/scale all
       * show in the viewport; the pick AABB scales (rotation stays axis-aligned). */
      lrg_shape3d_set_rotation_xyz (LRG_SHAPE3D (shape), rrx, rry, rrz);
      lrg_shape3d_set_scale_xyz (LRG_SHAPE3D (shape), ssx, ssy, ssz);
      hw *= fabsf (ssx); hh *= fabsf (ssy); hd *= fabsf (ssz);
      lrg_shape_set_color (shape, col);
      cmacs_libregnum_render_ctx_add_drawable (r, shape);
    }

  /* Record a scene node (even empties) so the outliner shows the tree.
   * The node path carries the stable guid for round-tripping. */
  id = (gint) cmacs_libregnum_render_ctx_add_node
                (r, lrg_node_get_guid (node), name ? name : "(node)",
                 FALSE, depth, parent, x, y, z, hw, hh, hd);
  g_ptr_array_add (r->editor_node_map, node);

  children = lrg_node_get_children (node);
  for (i = 0; children && i < children->len; i++)
    cmacs_editor_bake_node (r, g_ptr_array_index (children, i),
                            depth + 1, id);
}

static void
cmacs_editor_rebuild (CmacsLibregnumRenderCtx *r)
{
  LrgLevel  *level;
  LrgNode   *root;
  GPtrArray *children;
  guint      i;
  LrgNode   *sel;

  cmacs_libregnum_render_ctx_clear_drawables (r);  /* clears nodes + selection */
  if (r->editor_node_map)
    g_ptr_array_set_size (r->editor_node_map, 0);
  /* Drop any mesh-asset models from the previous bake. */
  if (r->editor_models)
    {
      guint mi;
      for (mi = 0; mi < r->editor_models->len; mi++)
        {
          CmacsEditorModel *em = &g_array_index (r->editor_models,
                                                 CmacsEditorModel, mi);
          g_clear_object (&em->model);
          g_clear_object (&em->texture);
          g_clear_pointer (&em->tiles, g_free);
          g_clear_pointer (&em->tile_rgb, g_free);
          g_clear_pointer (&em->tile_models, g_hash_table_destroy);
          g_clear_pointer (&em->tile_textures, g_ptr_array_unref);
        }
      g_array_set_size (r->editor_models, 0);
    }
  else
    r->editor_models = g_array_new (FALSE, FALSE, sizeof (CmacsEditorModel));
  if (!r->editor)
    return;

  level = lrg_editor_get_level (r->editor);
  if (!level)
    return;
  root = lrg_level_get_root (level);
  children = lrg_node_get_children (root);
  for (i = 0; children && i < children->len; i++)
    cmacs_editor_bake_node (r, g_ptr_array_index (children, i), 0, -1);

  /* Reflect the editor's primary selection as the highlighted node. */
  sel = lrg_editor_selection_get_primary (lrg_editor_get_selection (r->editor));
  if (sel)
    for (i = 0; i < r->editor_node_map->len; i++)
      if (g_ptr_array_index (r->editor_node_map, i) == sel)
        {
          cmacs_libregnum_render_ctx_set_selected (r, (gint) i);
          break;
        }

  /* If shading was already ON before this rebuild, re-attach the lighting
   * material to the freshly-baked models so they stay lit. */
  if (r->shading)
    ctx_attach_shading_materials (r, TRUE);
}

static LrgNode *
cmacs_editor_node_for_id (CmacsLibregnumRenderCtx *r, gint id)
{
  if (!r || !r->editor_node_map || id < 0
      || (guint) id >= r->editor_node_map->len)
    return NULL;
  return g_ptr_array_index (r->editor_node_map, id);
}

gboolean
cmacs_libregnum_render_ctx_editor_new (CmacsLibregnumRenderCtx *r)
{
  if (!r) return FALSE;
  g_clear_object (&r->editor);
  r->editor = lrg_editor_new ();
  if (!r->editor_node_map) r->editor_node_map = g_ptr_array_new ();
  if (r->gizmo_tool == 0) r->gizmo_tool = 1;   /* default: translate handles */
  cmacs_editor_rebuild (r);
  return TRUE;
}

gboolean
cmacs_libregnum_render_ctx_editor_open (CmacsLibregnumRenderCtx *r,
                                        const char *path, char **error_msg)
{
  GError *e = NULL;
  if (!r) return FALSE;
  if (!r->editor) r->editor = lrg_editor_new ();
  if (!r->editor_node_map) r->editor_node_map = g_ptr_array_new ();
  if (!lrg_editor_load_level (r->editor, path, &e))
    {
      if (error_msg) *error_msg = g_strdup (e ? e->message : "load failed");
      g_clear_error (&e);
      return FALSE;
    }
  cmacs_editor_rebuild (r);
  return TRUE;
}

gboolean
cmacs_libregnum_render_ctx_editor_save (CmacsLibregnumRenderCtx *r,
                                        const char *path, char **error_msg)
{
  GError *e = NULL;
  if (!r || !r->editor) return FALSE;
  if (!lrg_editor_save_level (r->editor, path, &e))
    {
      if (error_msg) *error_msg = g_strdup (e ? e->message : "save failed");
      g_clear_error (&e);
      return FALSE;
    }
  return TRUE;
}

void
cmacs_libregnum_render_ctx_editor_close (CmacsLibregnumRenderCtx *r)
{
  if (!r) return;
  g_clear_object (&r->editor);
  if (r->editor_node_map) g_ptr_array_set_size (r->editor_node_map, 0);
  cmacs_libregnum_render_ctx_clear_drawables (r);
}

gboolean
cmacs_libregnum_render_ctx_editor_active (CmacsLibregnumRenderCtx *r)
{
  return r && r->editor != NULL;
}

gint
cmacs_libregnum_render_ctx_editor_add_primitive (CmacsLibregnumRenderCtx *r,
                                                 int prim, const char *name)
{
  LrgNode       *node;
  LrgNodeVisual *vis;
  guint          i;

  if (!r || !r->editor) return -1;

  node = lrg_node_new (name ? name : "Object");
  vis = lrg_node_visual_new (LRG_NODE_VISUAL_PRIMITIVE);
  lrg_node_visual_set_primitive (vis, (LrgPrimitiveType) prim);
  lrg_node_set_visual (node, vis);
  g_object_unref (vis);

  lrg_editor_add_node (r->editor, node, NULL);   /* selects the new node */
  g_object_unref (node);                          /* editor holds a ref */

  cmacs_editor_rebuild (r);

  for (i = 0; i < r->editor_node_map->len; i++)
    if (g_ptr_array_index (r->editor_node_map, i) == node)
      return (gint) i;
  return -1;
}

void
cmacs_libregnum_render_ctx_editor_delete (CmacsLibregnumRenderCtx *r, gint id)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  if (n && r->editor)
    {
      lrg_editor_delete_node (r->editor, n);
      cmacs_editor_rebuild (r);
    }
}

void
cmacs_libregnum_render_ctx_editor_select_node (CmacsLibregnumRenderCtx *r,
                                               gint id)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  if (r && r->editor)
    lrg_editor_select (r->editor, n, FALSE);
  cmacs_libregnum_render_ctx_set_selected (r, id);
}

void
cmacs_libregnum_render_ctx_editor_set_position (CmacsLibregnumRenderCtx *r,
                                                gint id,
                                                double x, double y, double z)
{
  LrgNode    *n = cmacs_editor_node_for_id (r, id);
  GrlVector3 *rot, *scl;
  float       loc3[3], rot3[3], scl3[3];

  if (!n || !r->editor) return;

  rot = lrg_node_get_rotation (n);
  scl = lrg_node_get_scale (n);
  loc3[0] = (float) x; loc3[1] = (float) y; loc3[2] = (float) z;
  rot3[0] = rot ? rot->x : 0.0f; rot3[1] = rot ? rot->y : 0.0f; rot3[2] = rot ? rot->z : 0.0f;
  scl3[0] = scl ? scl->x : 1.0f; scl3[1] = scl ? scl->y : 1.0f; scl3[2] = scl ? scl->z : 1.0f;

  lrg_editor_set_node_transform (r->editor, n, loc3, rot3, scl3);
  cmacs_editor_rebuild (r);
}

void
cmacs_libregnum_render_ctx_editor_undo (CmacsLibregnumRenderCtx *r)
{
  if (r && r->editor) { lrg_editor_undo (r->editor); cmacs_editor_rebuild (r); }
}

void
cmacs_libregnum_render_ctx_editor_redo (CmacsLibregnumRenderCtx *r)
{
  if (r && r->editor) { lrg_editor_redo (r->editor); cmacs_editor_rebuild (r); }
}

gboolean
cmacs_libregnum_render_ctx_editor_can_undo (CmacsLibregnumRenderCtx *r)
{
  return r && r->editor && lrg_editor_can_undo (r->editor);
}

gboolean
cmacs_libregnum_render_ctx_editor_can_redo (CmacsLibregnumRenderCtx *r)
{
  return r && r->editor && lrg_editor_can_redo (r->editor);
}

const char *
cmacs_libregnum_render_ctx_editor_node_guid (CmacsLibregnumRenderCtx *r,
                                             gint id)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  return n ? lrg_node_get_guid (n) : NULL;
}

/* Intersect the cursor ray (view-local VX,VY in a VW×VH viewport) with the
 * horizontal plane Y=PLANE_Y; report the world (x,z) hit.  Returns FALSE if
 * the ray is parallel to the plane or the hit is behind the camera. */
static gboolean
ctx_screen_to_plane (CmacsLibregnumRenderCtx *r, double vx, double vy,
                     int vw, int vh, float plane_y,
                     float *out_x, float *out_z)
{
  Camera3D cam;
  Ray      ray;
  float    t;

  if (!r || vw <= 0 || vh <= 0) return FALSE;
  cam = ctx_raylib_camera (r);
  ray = GetScreenToWorldRayEx ((Vector2){ (float) vx, (float) vy },
                               cam, vw, vh);
  if (fabsf (ray.direction.y) < 1e-5f) return FALSE;
  t = (plane_y - ray.position.y) / ray.direction.y;
  if (t < 0.0f) return FALSE;
  if (out_x) *out_x = ray.position.x + ray.direction.x * t;
  if (out_z) *out_z = ray.position.z + ray.direction.z * t;
  return TRUE;
}

gboolean
cmacs_libregnum_render_ctx_editor_node_location (CmacsLibregnumRenderCtx *r,
                                                 gint id, double *x,
                                                 double *y, double *z)
{
  LrgNode    *n = cmacs_editor_node_for_id (r, id);
  GrlVector3 *l;
  if (!n) return FALSE;
  l = lrg_node_get_location (n);
  if (!l) return FALSE;
  if (x) *x = l->x;
  if (y) *y = l->y;
  if (z) *z = l->z;
  return TRUE;
}

void
cmacs_libregnum_render_ctx_editor_set_snap (CmacsLibregnumRenderCtx *r,
                                            double snap)
{
  if (r) r->editor_snap = (snap > 0.0) ? (float) snap : 0.0f;
}

gboolean
cmacs_libregnum_render_ctx_editor_dragging (CmacsLibregnumRenderCtx *r)
{
  return r && r->editor_dragging;
}

/* Begin a drag of baked node ID grabbed at view-local (VX,VY).  Records the
 * node's start location and the grab offset so it does not jump under the
 * cursor.  The drag plane is horizontal at the node's current Y. */
gboolean
cmacs_libregnum_render_ctx_editor_drag_begin (CmacsLibregnumRenderCtx *r,
                                              gint id, double vx, double vy,
                                              int vw, int vh)
{
  LrgNode    *n = cmacs_editor_node_for_id (r, id);
  GrlVector3 *l;
  float       gx = 0.0f, gz = 0.0f;

  if (!r || !r->editor || !n) return FALSE;
  l = lrg_node_get_location (n);
  if (!l) return FALSE;
  r->editor_drag_start[0] = l->x;
  r->editor_drag_start[1] = l->y;
  r->editor_drag_start[2] = l->z;
  if (ctx_screen_to_plane (r, vx, vy, vw, vh, l->y, &gx, &gz))
    {
      r->editor_drag_offset[0] = l->x - gx;
      r->editor_drag_offset[1] = l->z - gz;
    }
  else
    {
      r->editor_drag_offset[0] = 0.0f;
      r->editor_drag_offset[1] = 0.0f;
    }
  r->editor_drag_id = id;
  r->editor_dragging = TRUE;
  return TRUE;
}

/* Move the dragged node to track view-local (VX,VY) on its drag plane.
 * Live (no undo command); rebakes so the viewport updates immediately. */
gboolean
cmacs_libregnum_render_ctx_editor_drag_update (CmacsLibregnumRenderCtx *r,
                                               double vx, double vy,
                                               int vw, int vh)
{
  LrgNode *n;
  float    gx = 0.0f, gz = 0.0f, y, nx, nz;

  if (!r || !r->editor_dragging) return FALSE;
  n = cmacs_editor_node_for_id (r, r->editor_drag_id);
  if (!n) return FALSE;
  y = r->editor_drag_start[1];
  if (!ctx_screen_to_plane (r, vx, vy, vw, vh, y, &gx, &gz)) return FALSE;
  nx = gx + r->editor_drag_offset[0];
  nz = gz + r->editor_drag_offset[1];
  if (r->editor_snap > 0.0f)
    {
      nx = roundf (nx / r->editor_snap) * r->editor_snap;
      nz = roundf (nz / r->editor_snap) * r->editor_snap;
    }
  lrg_node_set_location_xyz (n, nx, y, nz);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* Finish a drag: push a single coalesced transform command (start -> final)
 * so the whole drag is one undo step.  A no-op drag records nothing. */
void
cmacs_libregnum_render_ctx_editor_drag_end (CmacsLibregnumRenderCtx *r)
{
  LrgNode    *n;
  GrlVector3 *l, *rot, *scl;
  float       fx, fy, fz, loc3[3], rot3[3], scl3[3];

  if (!r || !r->editor_dragging) return;
  r->editor_dragging = FALSE;
  n = cmacs_editor_node_for_id (r, r->editor_drag_id);
  if (!n || !r->editor) return;
  l = lrg_node_get_location (n);
  if (!l) return;
  fx = l->x; fy = l->y; fz = l->z;
  if (fabsf (fx - r->editor_drag_start[0])
      + fabsf (fy - r->editor_drag_start[1])
      + fabsf (fz - r->editor_drag_start[2]) < 1e-4f)
    return;   /* never actually moved -- this was a click-select */

  /* Roll back to the start so set_node_transform records before=start. */
  lrg_node_set_location_xyz (n, r->editor_drag_start[0],
                             r->editor_drag_start[1],
                             r->editor_drag_start[2]);
  rot = lrg_node_get_rotation (n);
  scl = lrg_node_get_scale (n);
  loc3[0] = fx; loc3[1] = fy; loc3[2] = fz;
  rot3[0] = rot ? rot->x : 0.0f; rot3[1] = rot ? rot->y : 0.0f;
  rot3[2] = rot ? rot->z : 0.0f;
  scl3[0] = scl ? scl->x : 1.0f; scl3[1] = scl ? scl->y : 1.0f;
  scl3[2] = scl ? scl->z : 1.0f;
  lrg_editor_set_node_transform (r->editor, n, loc3, rot3, scl3);
  cmacs_editor_rebuild (r);
}

gboolean
cmacs_libregnum_render_ctx_editor_node_rotation (CmacsLibregnumRenderCtx *r,
                                                 gint id, double *x,
                                                 double *y, double *z)
{
  LrgNode    *n = cmacs_editor_node_for_id (r, id);
  GrlVector3 *v;
  if (!n) return FALSE;
  v = lrg_node_get_rotation (n);
  if (!v) return FALSE;
  if (x) *x = v->x;
  if (y) *y = v->y;
  if (z) *z = v->z;
  return TRUE;
}

gboolean
cmacs_libregnum_render_ctx_editor_node_scale (CmacsLibregnumRenderCtx *r,
                                              gint id, double *x,
                                              double *y, double *z)
{
  LrgNode    *n = cmacs_editor_node_for_id (r, id);
  GrlVector3 *v;
  if (!n) return FALSE;
  v = lrg_node_get_scale (n);
  if (!v) return FALSE;
  if (x) *x = v->x;
  if (y) *y = v->y;
  if (z) *z = v->z;
  return TRUE;
}

/* Set NODE-ID's rotation (radians), keeping its location + scale, as one
 * undoable transform command. */
void
cmacs_libregnum_render_ctx_editor_set_rotation (CmacsLibregnumRenderCtx *r,
                                                gint id,
                                                double x, double y, double z)
{
  LrgNode    *n = cmacs_editor_node_for_id (r, id);
  GrlVector3 *loc, *scl;
  float       l3[3], r3[3], s3[3];
  if (!n || !r->editor) return;
  loc = lrg_node_get_location (n);
  scl = lrg_node_get_scale (n);
  l3[0] = loc ? loc->x : 0.0f; l3[1] = loc ? loc->y : 0.0f;
  l3[2] = loc ? loc->z : 0.0f;
  r3[0] = (float) x; r3[1] = (float) y; r3[2] = (float) z;
  s3[0] = scl ? scl->x : 1.0f; s3[1] = scl ? scl->y : 1.0f;
  s3[2] = scl ? scl->z : 1.0f;
  lrg_editor_set_node_transform (r->editor, n, l3, r3, s3);
  cmacs_editor_rebuild (r);
}

/* Set NODE-ID's scale, keeping its location + rotation, as one undoable
 * transform command. */
void
cmacs_libregnum_render_ctx_editor_set_scale (CmacsLibregnumRenderCtx *r,
                                             gint id,
                                             double x, double y, double z)
{
  LrgNode    *n = cmacs_editor_node_for_id (r, id);
  GrlVector3 *loc, *rot;
  float       l3[3], r3[3], s3[3];
  if (!n || !r->editor) return;
  loc = lrg_node_get_location (n);
  rot = lrg_node_get_rotation (n);
  l3[0] = loc ? loc->x : 0.0f; l3[1] = loc ? loc->y : 0.0f;
  l3[2] = loc ? loc->z : 0.0f;
  r3[0] = rot ? rot->x : 0.0f; r3[1] = rot ? rot->y : 0.0f;
  r3[2] = rot ? rot->z : 0.0f;
  s3[0] = (float) x; s3[1] = (float) y; s3[2] = (float) z;
  lrg_editor_set_node_transform (r->editor, n, l3, r3, s3);
  cmacs_editor_rebuild (r);
}

/* Reparent CHILD-ID under PARENT-ID (PARENT-ID < 0 == the level root).
 * Returns FALSE if the move is invalid (e.g. a cycle). */
gboolean
cmacs_libregnum_render_ctx_editor_reparent (CmacsLibregnumRenderCtx *r,
                                            gint child_id, gint parent_id)
{
  LrgNode  *child = cmacs_editor_node_for_id (r, child_id);
  LrgNode  *parent;
  gboolean  ok;
  if (!r || !r->editor || !child) return FALSE;
  if (parent_id < 0)
    {
      LrgLevel *lvl = lrg_editor_get_level (r->editor);
      parent = lvl ? lrg_level_get_root (lvl) : NULL;
    }
  else
    parent = cmacs_editor_node_for_id (r, parent_id);
  if (!parent) return FALSE;
  ok = lrg_editor_reparent_node (r->editor, child, parent);
  if (ok) cmacs_editor_rebuild (r);
  return ok;
}

/* Add a node of visual KIND (LrgNodeVisualKind int) with optional ASSET path
 * (for MESH_ASSET / SPRITE), select it, and return its baked node id. */
gint
cmacs_libregnum_render_ctx_editor_add_visual (CmacsLibregnumRenderCtx *r,
                                              int kind, const char *asset,
                                              const char *name)
{
  LrgNode       *node;
  LrgNodeVisual *vis;
  guint          i;

  if (!r || !r->editor) return -1;
  node = lrg_node_new (name ? name : "Object");
  vis = lrg_node_visual_new ((LrgNodeVisualKind) kind);
  if (asset && asset[0])
    lrg_node_visual_set_asset (vis, asset);
  lrg_node_set_visual (node, vis);
  g_object_unref (vis);
  lrg_editor_add_node (r->editor, node, NULL);   /* selects the new node */
  g_object_unref (node);
  cmacs_editor_rebuild (r);
  for (i = 0; i < r->editor_node_map->len; i++)
    if (g_ptr_array_index (r->editor_node_map, i) == node)
      return (gint) i;
  return -1;
}

/* Attach a script binding (LANGUAGE is an LrgScriptLanguage int) to NODE-ID,
 * persisted in the level.  Returns FALSE if NODE-ID is invalid. */
gboolean
cmacs_libregnum_render_ctx_editor_attach_script (CmacsLibregnumRenderCtx *r,
                                                 gint id, int language,
                                                 const char *path)
{
  LrgNode          *n = cmacs_editor_node_for_id (r, id);
  LrgScriptBinding *b;
  if (!n || !r->editor) return FALSE;
  b = lrg_script_binding_new ((LrgScriptLanguage) language, path);
  lrg_node_add_script (n, b);
  g_object_unref (b);
  cmacs_editor_rebuild (r);
  return TRUE;
}

gint
cmacs_libregnum_render_ctx_editor_node_script_count (CmacsLibregnumRenderCtx *r,
                                                     gint id)
{
  LrgNode   *n = cmacs_editor_node_for_id (r, id);
  GPtrArray *s;
  if (!n) return -1;
  s = lrg_node_get_scripts (n);
  return s ? (gint) s->len : 0;
}

/* Play-in-editor: instantiate the level into a throwaway LrgWorld and run it
 * (logic/components execute; the doc is never mutated).  Returns FALSE if
 * instantiation fails. */
gboolean
cmacs_libregnum_render_ctx_editor_play (CmacsLibregnumRenderCtx *r)
{
  LrgLevel  *level;
  LrgEngine *engine;
  GError    *e = NULL;

  if (!r || !r->editor) return FALSE;
  level = lrg_editor_get_level (r->editor);
  if (!level) return FALSE;
  g_clear_object (&r->play_world);
  r->play_world = lrg_world_new ();
  engine = lrg_engine_get_default ();
  if (!lrg_level_instantiate (level, r->play_world, engine, &e))
    {
      g_clear_error (&e);
      g_clear_object (&r->play_world);
      return FALSE;
    }
  r->playing = TRUE;
  return TRUE;
}

void
cmacs_libregnum_render_ctx_editor_stop (CmacsLibregnumRenderCtx *r)
{
  if (!r) return;
  r->playing = FALSE;
  g_clear_object (&r->play_world);
}

gboolean
cmacs_libregnum_render_ctx_editor_playing (CmacsLibregnumRenderCtx *r)
{
  return r && r->playing;
}

/* Advance the running world by DELTA seconds (no-op unless playing). */
gboolean
cmacs_libregnum_render_ctx_editor_play_tick (CmacsLibregnumRenderCtx *r,
                                             double delta)
{
  if (!r || !r->playing || !r->play_world) return FALSE;
  lrg_world_update (r->play_world, (gfloat) delta);
  cmacs_libregnum_render_ctx_editor_sync_play (r);
  return TRUE;
}

/* ── On-screen transform gizmo ─────────────────────────────────────── */

static const Vector3 GIZMO_AXES[3] = {
  { 1.0f, 0.0f, 0.0f }, { 0.0f, 1.0f, 0.0f }, { 0.0f, 0.0f, 1.0f }
};

/* Parameter s minimising the distance between the axis line (o + s*axis,
 * axis unit) and the mouse RAY.  Standard closest-point-of-two-lines. */
static float
gizmo_axis_param (Vector3 o, Vector3 axis, Ray ray)
{
  Vector3 v = ray.direction;
  float w0x = o.x - ray.position.x;
  float w0y = o.y - ray.position.y;
  float w0z = o.z - ray.position.z;
  float b = axis.x*v.x + axis.y*v.y + axis.z*v.z;
  float c = v.x*v.x + v.y*v.y + v.z*v.z;
  float d = axis.x*w0x + axis.y*w0y + axis.z*w0z;
  float e = v.x*w0x + v.y*w0y + v.z*w0z;
  float denom = c - b*b;            /* axis.axis == 1 */
  if (fabsf (denom) < 1e-6f) return 0.0f;
  return (b*e - c*d) / denom;
}

/* Two unit vectors spanning the plane perpendicular to axis AX. */
static void
gizmo_ring_basis (int ax, Vector3 *u, Vector3 *v)
{
  if (ax == 0)      { *u = GIZMO_AXES[1]; *v = GIZMO_AXES[2]; }
  else if (ax == 1) { *u = GIZMO_AXES[0]; *v = GIZMO_AXES[2]; }
  else              { *u = GIZMO_AXES[0]; *v = GIZMO_AXES[1]; }
}

/* Angle (radians) of the mouse RAY's hit on the ring plane (normal = axis AX)
 * about center C. */
static float
gizmo_ring_angle (Vector3 c, int ax, Ray ray)
{
  Vector3 nrm = GIZMO_AXES[ax], u, v;
  float denom = ray.direction.x*nrm.x + ray.direction.y*nrm.y
              + ray.direction.z*nrm.z;
  float t, hx, hy, hz;
  if (fabsf (denom) < 1e-5f) return 0.0f;
  t = ((c.x-ray.position.x)*nrm.x + (c.y-ray.position.y)*nrm.y
       + (c.z-ray.position.z)*nrm.z) / denom;
  hx = ray.position.x + ray.direction.x*t - c.x;
  hy = ray.position.y + ray.direction.y*t - c.y;
  hz = ray.position.z + ray.direction.z*t - c.z;
  gizmo_ring_basis (ax, &u, &v);
  return atan2f (hx*v.x + hy*v.y + hz*v.z, hx*u.x + hy*u.y + hz*u.z);
}

/* Selection center + handle length, or FALSE when nothing is selected. */
static gboolean
gizmo_center (CmacsLibregnumRenderCtx *r, Vector3 *out_c, float *out_len)
{
  CmacsNode *n;
  if (!r || r->selected < 0 || !r->nodes
      || (guint) r->selected >= r->nodes->len)
    return FALSE;
  n = &g_array_index (r->nodes, CmacsNode, (guint) r->selected);
  if (out_c) { out_c->x = n->x; out_c->y = n->y; out_c->z = n->z; }
  if (out_len) *out_len = fmaxf (n->hw, fmaxf (n->hh, n->hd)) + 1.2f;
  return TRUE;
}

/* Draw the active tool's handles at the selection (in the 3D layer). */
static void
cmacs_editor_draw_gizmo (CmacsLibregnumRenderCtx *r)
{
  Vector3 c;
  float   len;
  int     ax;
  Color   cols[3] = { (Color){ 230, 80, 80, 255 },
                      (Color){ 90, 210, 90, 255 },
                      (Color){ 90, 140, 240, 255 } };
  if (!r->editor || r->gizmo_tool == 0 || !gizmo_center (r, &c, &len))
    return;
  for (ax = 0; ax < 3; ax++)
    {
      Vector3 a = GIZMO_AXES[ax];
      Vector3 tip = { c.x + a.x*len, c.y + a.y*len, c.z + a.z*len };
      Color col = (r->gizmo_dragging && r->gizmo_axis == ax)
                    ? (Color){ 255, 235, 120, 255 } : cols[ax];
      if (r->gizmo_tool == 1)            /* translate: shaft + cone tip */
        {
          Vector3 t2 = { c.x + a.x*(len+0.3f), c.y + a.y*(len+0.3f),
                         c.z + a.z*(len+0.3f) };
          DrawLine3D (c, tip, col);
          DrawCylinderEx (tip, t2, 0.12f, 0.0f, 8, col);
        }
      else if (r->gizmo_tool == 3)       /* scale: shaft + cube tip */
        {
          DrawLine3D (c, tip, col);
          DrawCube (tip, 0.22f, 0.22f, 0.22f, col);
        }
      else                               /* rotate: ring in the axis plane */
        {
          Vector3 u, v;
          int i;
          gizmo_ring_basis (ax, &u, &v);
          for (i = 0; i < 32; i++)
            {
              float t0 = (float) i / 32.0f * 2.0f * 3.14159265f;
              float t1 = (float) (i+1) / 32.0f * 2.0f * 3.14159265f;
              Vector3 p0 = { c.x + (u.x*cosf(t0)+v.x*sinf(t0))*len,
                             c.y + (u.y*cosf(t0)+v.y*sinf(t0))*len,
                             c.z + (u.z*cosf(t0)+v.z*sinf(t0))*len };
              Vector3 p1 = { c.x + (u.x*cosf(t1)+v.x*sinf(t1))*len,
                             c.y + (u.y*cosf(t1)+v.y*sinf(t1))*len,
                             c.z + (u.z*cosf(t1)+v.z*sinf(t1))*len };
              DrawLine3D (p0, p1, col);
            }
        }
    }
}

/* Which gizmo axis (0/1/2) the cursor is over, or -1. */
static int
cmacs_editor_gizmo_axis_at (CmacsLibregnumRenderCtx *r, double vx, double vy,
                            int vw, int vh)
{
  Vector3 c;
  float   len, bestd = 0.0f;
  Camera3D cam;
  Ray     ray;
  int     ax, best = -1;
  if (!r->editor || r->gizmo_tool == 0 || !gizmo_center (r, &c, &len)
      || vw <= 0 || vh <= 0)
    return -1;
  cam = ctx_raylib_camera (r);
  ray = GetScreenToWorldRayEx ((Vector2){ (float) vx, (float) vy },
                               cam, vw, vh);
  if (r->gizmo_tool == 2)               /* rotate: nearest ring */
    {
      for (ax = 0; ax < 3; ax++)
        {
          Vector3 nrm = GIZMO_AXES[ax];
          float denom = ray.direction.x*nrm.x + ray.direction.y*nrm.y
                      + ray.direction.z*nrm.z;
          float t, hx, hy, hz, dist;
          if (fabsf (denom) < 1e-5f) continue;
          t = ((c.x-ray.position.x)*nrm.x + (c.y-ray.position.y)*nrm.y
               + (c.z-ray.position.z)*nrm.z) / denom;
          if (t < 0.0f) continue;
          hx = ray.position.x + ray.direction.x*t - c.x;
          hy = ray.position.y + ray.direction.y*t - c.y;
          hz = ray.position.z + ray.direction.z*t - c.z;
          dist = sqrtf (hx*hx + hy*hy + hz*hz);
          if (fabsf (dist - len) < 0.4f && (best < 0 || t < bestd))
            { best = ax; bestd = t; }
        }
      return best;
    }
  /* translate / scale: thin AABB along each shaft (offset from center so the
   * node body itself is not mistaken for a handle). */
  for (ax = 0; ax < 3; ax++)
    {
      Vector3 a = GIZMO_AXES[ax];
      float th = 0.22f;
      Vector3 s = { c.x + a.x*0.25f*len, c.y + a.y*0.25f*len,
                    c.z + a.z*0.25f*len };
      Vector3 e = { c.x + a.x*(len+0.3f), c.y + a.y*(len+0.3f),
                    c.z + a.z*(len+0.3f) };
      BoundingBox bb = { { fminf(s.x,e.x)-th, fminf(s.y,e.y)-th,
                           fminf(s.z,e.z)-th },
                         { fmaxf(s.x,e.x)+th, fmaxf(s.y,e.y)+th,
                           fmaxf(s.z,e.z)+th } };
      RayCollision rc = GetRayCollisionBox (ray, bb);
      if (rc.hit && (best < 0 || rc.distance < bestd))
        { best = ax; bestd = rc.distance; }
    }
  return best;
}

gboolean
cmacs_libregnum_render_ctx_editor_gizmo_active (CmacsLibregnumRenderCtx *r)
{
  return r && r->gizmo_dragging;
}

void
cmacs_libregnum_render_ctx_editor_set_tool (CmacsLibregnumRenderCtx *r, int tool)
{
  if (r) r->gizmo_tool = tool;
}

gint
cmacs_libregnum_render_ctx_editor_get_tool (CmacsLibregnumRenderCtx *r)
{
  return r ? r->gizmo_tool : 0;
}

/* Returns TRUE if a gizmo handle is under (VX,VY); used by input routing to
 * decide between gizmo-drag, object-move, and camera-orbit. */
gboolean
cmacs_libregnum_render_ctx_editor_gizmo_hit (CmacsLibregnumRenderCtx *r,
                                             double vx, double vy,
                                             int vw, int vh)
{
  return cmacs_editor_gizmo_axis_at (r, vx, vy, vw, vh) >= 0;
}

gboolean
cmacs_libregnum_render_ctx_editor_gizmo_begin (CmacsLibregnumRenderCtx *r,
                                               double vx, double vy,
                                               int vw, int vh)
{
  int       ax;
  LrgNode  *n;
  GrlVector3 *v;
  Vector3   c;
  float     len;
  Camera3D  cam;
  Ray       ray;

  if (!r || !r->editor) return FALSE;
  ax = cmacs_editor_gizmo_axis_at (r, vx, vy, vw, vh);
  if (ax < 0) return FALSE;
  n = cmacs_editor_node_for_id (r, r->selected);
  if (!n) return FALSE;
  if (r->gizmo_tool == 1)      v = lrg_node_get_location (n);
  else if (r->gizmo_tool == 3) v = lrg_node_get_scale (n);
  else                         v = lrg_node_get_rotation (n);
  if (!v) return FALSE;
  r->gizmo_start[0] = v->x; r->gizmo_start[1] = v->y; r->gizmo_start[2] = v->z;
  gizmo_center (r, &c, &len);
  r->gizmo_center0[0] = c.x; r->gizmo_center0[1] = c.y; r->gizmo_center0[2] = c.z;
  cam = ctx_raylib_camera (r);
  ray = GetScreenToWorldRayEx ((Vector2){ (float) vx, (float) vy },
                               cam, vw, vh);
  r->gizmo_grab = (r->gizmo_tool == 2)
                    ? gizmo_ring_angle (c, ax, ray)
                    : gizmo_axis_param (c, GIZMO_AXES[ax], ray);
  r->gizmo_axis = ax;
  r->gizmo_dragging = TRUE;
  return TRUE;
}

gboolean
cmacs_libregnum_render_ctx_editor_gizmo_drag (CmacsLibregnumRenderCtx *r,
                                              double vx, double vy,
                                              int vw, int vh)
{
  LrgNode    *n;
  GrlVector3 *gl, *gr, *gs;
  Vector3     c0;
  Camera3D    cam;
  Ray         ray;
  int         ax;
  float       cur, delta, t3[3];

  if (!r || !r->gizmo_dragging) return FALSE;
  n = cmacs_editor_node_for_id (r, r->selected);
  if (!n) return FALSE;
  ax = r->gizmo_axis;
  c0 = (Vector3){ r->gizmo_center0[0], r->gizmo_center0[1],
                  r->gizmo_center0[2] };
  cam = ctx_raylib_camera (r);
  ray = GetScreenToWorldRayEx ((Vector2){ (float) vx, (float) vy },
                               cam, vw, vh);
  gl = lrg_node_get_location (n);
  gr = lrg_node_get_rotation (n);
  gs = lrg_node_get_scale (n);
  if (r->gizmo_tool == 1)            /* translate */
    {
      cur = gizmo_axis_param (c0, GIZMO_AXES[ax], ray);
      delta = cur - r->gizmo_grab;
      t3[0] = gl->x; t3[1] = gl->y; t3[2] = gl->z;
      t3[ax] = r->gizmo_start[ax] + delta;
      if (r->editor_snap > 0.0f)
        t3[ax] = roundf (t3[ax] / r->editor_snap) * r->editor_snap;
      lrg_node_set_location_xyz (n, t3[0], t3[1], t3[2]);
    }
  else if (r->gizmo_tool == 3)       /* scale */
    {
      cur = gizmo_axis_param (c0, GIZMO_AXES[ax], ray);
      delta = cur - r->gizmo_grab;
      t3[0] = gs->x; t3[1] = gs->y; t3[2] = gs->z;
      t3[ax] = fmaxf (0.05f, r->gizmo_start[ax] + delta);
      lrg_node_set_scale_xyz (n, t3[0], t3[1], t3[2]);
    }
  else                               /* rotate */
    {
      cur = gizmo_ring_angle (c0, ax, ray);
      delta = cur - r->gizmo_grab;
      t3[0] = gr->x; t3[1] = gr->y; t3[2] = gr->z;
      t3[ax] = r->gizmo_start[ax] + delta;
      lrg_node_set_rotation_xyz (n, t3[0], t3[1], t3[2]);
    }
  cmacs_editor_rebuild (r);
  return TRUE;
}

void
cmacs_libregnum_render_ctx_editor_gizmo_end (CmacsLibregnumRenderCtx *r)
{
  LrgNode    *n;
  GrlVector3 *gl, *gr, *gs;
  float       loc3[3], rot3[3], scl3[3], fin[3];
  int         ax, tool;

  if (!r || !r->gizmo_dragging) return;
  tool = r->gizmo_tool;
  ax = r->gizmo_axis;
  r->gizmo_dragging = FALSE;
  r->gizmo_axis = -1;
  n = cmacs_editor_node_for_id (r, r->selected);
  if (!n || !r->editor) return;

  gl = lrg_node_get_location (n);
  gr = lrg_node_get_rotation (n);
  gs = lrg_node_get_scale (n);
  /* The tool's component holds the final dragged value. */
  if (tool == 1)      { fin[0]=gl->x; fin[1]=gl->y; fin[2]=gl->z; }
  else if (tool == 3) { fin[0]=gs->x; fin[1]=gs->y; fin[2]=gs->z; }
  else                { fin[0]=gr->x; fin[1]=gr->y; fin[2]=gr->z; }

  if (fabsf (fin[0]-r->gizmo_start[0]) + fabsf (fin[1]-r->gizmo_start[1])
      + fabsf (fin[2]-r->gizmo_start[2]) < 1e-4f)
    return;   /* no real change -- record nothing */

  /* Roll the tool's component back to the start so set_node_transform records
   * before=start; then push one coalesced command applying the final value. */
  if (tool == 1)      lrg_node_set_location_xyz (n, r->gizmo_start[0],
                                                 r->gizmo_start[1],
                                                 r->gizmo_start[2]);
  else if (tool == 3) lrg_node_set_scale_xyz (n, r->gizmo_start[0],
                                              r->gizmo_start[1],
                                              r->gizmo_start[2]);
  else                lrg_node_set_rotation_xyz (n, r->gizmo_start[0],
                                                 r->gizmo_start[1],
                                                 r->gizmo_start[2]);
  gl = lrg_node_get_location (n);
  gr = lrg_node_get_rotation (n);
  gs = lrg_node_get_scale (n);
  loc3[0]=gl->x; loc3[1]=gl->y; loc3[2]=gl->z;
  rot3[0]=gr->x; rot3[1]=gr->y; rot3[2]=gr->z;
  scl3[0]=gs->x; scl3[1]=gs->y; scl3[2]=gs->z;
  if (tool == 1)      { loc3[0]=fin[0]; loc3[1]=fin[1]; loc3[2]=fin[2]; }
  else if (tool == 3) { scl3[0]=fin[0]; scl3[1]=fin[1]; scl3[2]=fin[2]; }
  else                { rot3[0]=fin[0]; rot3[1]=fin[1]; rot3[2]=fin[2]; }
  (void) ax;
  lrg_editor_set_node_transform (r->editor, n, loc3, rot3, scl3);
  cmacs_editor_rebuild (r);
}

/* Toggle a top-down orthographic 2D view (for 2D levels), or restore the
 * default perspective.  Picking/projection honour the projection too. */
void
cmacs_libregnum_render_ctx_editor_set_view_2d (CmacsLibregnumRenderCtx *r,
                                               gboolean on)
{
  LrgCamera3D *c3;
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
  c3 = LRG_CAMERA3D (r->camera);
  if (on)
    {
      g_autoptr (GrlVector3) t = lrg_camera3d_get_target (c3);
      float tx = t ? t->x : 0.0f, tz = t ? t->z : 0.0f;
      lrg_camera3d_set_target_xyz (c3, tx, 0.0f, tz);
      lrg_camera3d_set_position_xyz (c3, tx, 20.0f, tz);
      lrg_camera3d_set_up_xyz (c3, 0.0f, 0.0f, -1.0f);
      lrg_camera3d_set_fovy (c3, 20.0f);   /* ortho vertical extent */
      lrg_camera3d_set_projection (c3, LRG_PROJECTION_ORTHOGRAPHIC);
    }
  else
    {
      lrg_camera3d_set_projection (c3, LRG_PROJECTION_PERSPECTIVE);
      lrg_camera3d_set_position_xyz (c3, 8.0f, 6.0f, 12.0f);
      lrg_camera3d_set_target_xyz (c3, 0.0f, 0.0f, 0.0f);
      lrg_camera3d_set_up_xyz (c3, 0.0f, 1.0f, 0.0f);
      lrg_camera3d_set_fovy (c3, 60.0f);
    }
}

gboolean
cmacs_libregnum_render_ctx_editor_view_2d (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return FALSE;
  return lrg_camera3d_get_projection (LRG_CAMERA3D (r->camera))
           == LRG_PROJECTION_ORTHOGRAPHIC;
}

/* Asset drop-at-point: arm so the next viewport click drops the armed asset
 * at the ground point under the cursor (the input layer + Elisp cooperate). */
void
cmacs_libregnum_render_ctx_editor_set_armed (CmacsLibregnumRenderCtx *r,
                                             gboolean on)
{
  if (r) r->place_armed = on;
}

gboolean
cmacs_libregnum_render_ctx_editor_armed (CmacsLibregnumRenderCtx *r)
{
  return r && r->place_armed;
}

/* World point on the ground plane (Y=0) under view-local (VX,VY).  Used to
 * drop assets where the user clicks. */
gboolean
cmacs_libregnum_render_ctx_editor_screen_to_ground (CmacsLibregnumRenderCtx *r,
                                                    double vx, double vy,
                                                    int vw, int vh,
                                                    double *x, double *y,
                                                    double *z)
{
  float gx = 0.0f, gz = 0.0f;
  if (!ctx_screen_to_plane (r, vx, vy, vw, vh, 0.0f, &gx, &gz))
    return FALSE;
  if (x) *x = gx;
  if (y) *y = 0.0;
  if (z) *z = gz;
  return TRUE;
}

/* ── Tilemap data (stored in the node's visual params; persists in .rlevel) ── */

/* Read the "tiles" CSV param into a fresh mw*mh gint array (-1 default). */
static gint *
tilemap_read_tiles (LrgNodeVisual *vis, int mw, int mh)
{
  int n = mw * mh, i;
  gint *tiles = g_new (gint, n > 0 ? n : 1);
  const GValue *tv = lrg_node_visual_get_param (vis, "tiles");
  for (i = 0; i < n; i++)
    tiles[i] = -1;
  if (tv != NULL && G_VALUE_HOLDS_STRING (tv))
    {
      const char *csv = g_value_get_string (tv);
      gchar **parts = g_strsplit (csv ? csv : "", ",", -1);
      for (i = 0; parts && parts[i] != NULL && i < n; i++)
        if (parts[i][0] != '\0')
          tiles[i] = (gint) g_ascii_strtoll (parts[i], NULL, 10);
      g_strfreev (parts);
    }
  return tiles;
}

/* Write a gint tile array back to the "tiles" string param as CSV. */
static void
tilemap_write_tiles (LrgNodeVisual *vis, const gint *tiles, int n)
{
  GString *csv = g_string_new (NULL);
  GValue v = G_VALUE_INIT;
  int i;
  for (i = 0; i < n; i++)
    g_string_append_printf (csv, (i == 0) ? "%d" : ",%d", tiles[i]);
  g_value_init (&v, G_TYPE_STRING);
  g_value_set_string (&v, csv->str);
  lrg_node_visual_set_param (vis, "tiles", &v);
  g_value_unset (&v);
  g_string_free (csv, TRUE);
}

static LrgNodeVisual *
tilemap_ensure_visual (LrgNode *n)
{
  LrgNodeVisual *vis = lrg_node_get_visual (n);
  if (vis == NULL)
    {
      vis = lrg_node_visual_new (LRG_NODE_VISUAL_TILEMAP);
      lrg_node_set_visual (n, vis);
      g_object_unref (vis);
      vis = lrg_node_get_visual (n);
    }
  lrg_node_visual_set_kind (vis, LRG_NODE_VISUAL_TILEMAP);
  return vis;
}

/* Configure NODE-ID as a tilemap: TILESET image, TW x TH tile pixels, COLS
 * tileset columns, MW x MH map cells.  Existing tiles within the overlap are
 * preserved on resize; new cells are empty (-1). */
void
cmacs_libregnum_render_ctx_editor_tilemap_config (CmacsLibregnumRenderCtx *r,
                                                  gint id, const char *tileset,
                                                  int tw, int th, int cols,
                                                  int mw, int mh)
{
  LrgNode       *n = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  int            old_mw, old_mh, nx, ny, cx, cy;
  gint          *old_tiles, *new_tiles;

  if (!n || mw <= 0 || mh <= 0) return;
  vis = tilemap_ensure_visual (n);
  if (tileset && tileset[0])
    lrg_node_visual_set_asset (vis, tileset);
  old_mw = (int) lrg_node_visual_get_param_double (vis, "mw", 0.0);
  old_mh = (int) lrg_node_visual_get_param_double (vis, "mh", 0.0);
  old_tiles = tilemap_read_tiles (vis, old_mw, old_mh);
  new_tiles = g_new (gint, mw * mh);
  for (cy = 0; cy < mh; cy++)
    for (cx = 0; cx < mw; cx++)
      new_tiles[cy * mw + cx] =
        (cx < old_mw && cy < old_mh) ? old_tiles[cy * old_mw + cx] : -1;
  (void) nx; (void) ny;
  lrg_node_visual_set_param_double (vis, "tw", tw > 0 ? tw : 16);
  lrg_node_visual_set_param_double (vis, "th", th > 0 ? th : 16);
  lrg_node_visual_set_param_double (vis, "cols", cols > 0 ? cols : 1);
  lrg_node_visual_set_param_double (vis, "mw", mw);
  lrg_node_visual_set_param_double (vis, "mh", mh);
  tilemap_write_tiles (vis, new_tiles, mw * mh);
  g_free (old_tiles);
  g_free (new_tiles);
  cmacs_editor_rebuild (r);
}

/* Paint cell (CX,CY) of tilemap NODE-ID with TILE (-1 clears). */
void
cmacs_libregnum_render_ctx_editor_tilemap_set_tile (CmacsLibregnumRenderCtx *r,
                                                    gint id, int cx, int cy,
                                                    int tile)
{
  LrgNode       *n = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  int            mw, mh;
  gint          *tiles;

  if (!n) return;
  vis = lrg_node_get_visual (n);
  if (!vis) return;
  mw = (int) lrg_node_visual_get_param_double (vis, "mw", 0.0);
  mh = (int) lrg_node_visual_get_param_double (vis, "mh", 0.0);
  if (cx < 0 || cy < 0 || cx >= mw || cy >= mh) return;
  tiles = tilemap_read_tiles (vis, mw, mh);
  tiles[cy * mw + cx] = tile;
  tilemap_write_tiles (vis, tiles, mw * mh);
  g_free (tiles);
  cmacs_editor_rebuild (r);
}

/* Report tilemap NODE-ID's dimensions; FALSE if it is not a tilemap. */
gboolean
cmacs_libregnum_render_ctx_editor_tilemap_info (CmacsLibregnumRenderCtx *r,
                                                gint id, int *mw, int *mh,
                                                int *cols, int *tw, int *th)
{
  LrgNode       *n = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  if (!n) return FALSE;
  vis = lrg_node_get_visual (n);
  if (!vis || lrg_node_visual_get_kind (vis) != LRG_NODE_VISUAL_TILEMAP)
    return FALSE;
  if (mw)   *mw   = (int) lrg_node_visual_get_param_double (vis, "mw", 0.0);
  if (mh)   *mh   = (int) lrg_node_visual_get_param_double (vis, "mh", 0.0);
  if (cols) *cols = (int) lrg_node_visual_get_param_double (vis, "cols", 1.0);
  if (tw)   *tw   = (int) lrg_node_visual_get_param_double (vis, "tw", 16.0);
  if (th)   *th   = (int) lrg_node_visual_get_param_double (vis, "th", 16.0);
  return TRUE;
}

/* Play-rendering: reflect the running world's object positions back onto the
 * baked scene nodes + drawables, so script-driven motion is visible.  World
 * objects are created in the same depth-first order as nodes (1:1). */
void
cmacs_libregnum_render_ctx_editor_sync_play (CmacsLibregnumRenderCtx *r)
{
  GList *objects, *l;
  guint  i;
  if (!r || !r->playing || !r->play_world || !r->nodes) return;
  objects = lrg_world_get_objects (r->play_world);
  for (l = objects, i = 0; l != NULL && i < r->nodes->len; l = l->next, i++)
    {
      LrgGameObject *obj = l->data;
      g_autoptr (GrlVector2) p = NULL;
      CmacsNode *n;
      if (!LRG_IS_GAME_OBJECT (obj)) continue;
      p = grl_entity_get_position (GRL_ENTITY (obj));
      if (!p) continue;
      n = &g_array_index (r->nodes, CmacsNode, i);
      /* instantiate maps node (x,y) -> entity (x,y); reflect it back. */
      n->x = p->x;
      n->y = p->y;
      /* Move the drawable too when shapes are 1:1 with nodes (the common
       * all-primitive case); otherwise the wireframe still tracks. */
      if (r->drawables->len == r->nodes->len)
        {
          gpointer d = g_ptr_array_index (r->drawables, i);
          if (d && LRG_IS_SHAPE3D (d))
            lrg_shape3d_set_position_xyz (LRG_SHAPE3D (d), p->x, p->y, n->z);
        }
    }
}

/* Reverse of cmacs_editor_node_for_id: map a node pointer back to its id. */
static gint
cmacs_editor_id_for_node (CmacsLibregnumRenderCtx *r, LrgNode *node)
{
  guint i;
  if (!r || !r->editor_node_map || !node)
    return -1;
  for (i = 0; i < r->editor_node_map->len; i++)
    if (g_ptr_array_index (r->editor_node_map, i) == node)
      return (gint) i;
  return -1;
}

/* Return node ID's live LrgNode as a GObject* (cast to void*) with a fresh
 * reference (transfer full) so the Lisp wrapper's finalizer balances it; NULL
 * if absent. */
void *
cmacs_libregnum_render_ctx_editor_node_object (CmacsLibregnumRenderCtx *r,
                                               gint id)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  if (!n)
    return NULL;
  return g_object_ref (n);
}

/* Save node ID's subtree to a .rprefab file. */
gboolean
cmacs_libregnum_render_ctx_editor_save_prefab (CmacsLibregnumRenderCtx *r,
                                               gint id, const char *path)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  g_autoptr (GError) error = NULL;
  if (!n || !path)
    return FALSE;
  return lrg_prefab_save (n, path, &error);
}

/* Instantiate a .rprefab under PARENT_ID (-1 = root); return the new node id. */
gint
cmacs_libregnum_render_ctx_editor_instantiate_prefab (CmacsLibregnumRenderCtx *r,
                                                      const char *path,
                                                      gint parent_id)
{
  LrgNode *node, *parent, *sel;
  g_autoptr (GError) error = NULL;
  if (!r || !r->editor || !path)
    return -1;
  node = lrg_prefab_load (path, &error);
  if (!node)
    return -1;
  parent = (parent_id >= 0) ? cmacs_editor_node_for_id (r, parent_id) : NULL;
  lrg_editor_add_node (r->editor, node, parent);   /* refs + selects it */
  g_object_unref (node);
  cmacs_editor_rebuild (r);
  sel = lrg_editor_selection_get_primary (lrg_editor_get_selection (r->editor));
  return cmacs_editor_id_for_node (r, sel);
}

/* Import a Blender-exported scene YAML as the editor's current level. */
gboolean
cmacs_libregnum_render_ctx_editor_import_scene (CmacsLibregnumRenderCtx *r,
                                                const char *path)
{
  LrgSceneSerializerBlender *ser;
  LrgScene                  *scene;
  LrgLevel                  *level;
  g_autoptr (GError)         error = NULL;
  if (!r || !r->editor || !path)
    return FALSE;
  ser = lrg_scene_serializer_blender_new ();
  scene = lrg_scene_serializer_load_from_file (LRG_SCENE_SERIALIZER (ser),
                                               path, &error);
  g_object_unref (ser);
  if (!scene)
    return FALSE;
  level = lrg_level_from_scene (scene);
  g_object_unref (scene);
  if (!level)
    return FALSE;
  lrg_editor_set_level (r->editor, level);   /* g_set_object: refs internally */
  g_object_unref (level);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* Scripting-backend availability (singleton manager; no ctx needed). */
gint
cmacs_libregnum_scripting_language_count (void)
{
  LrgScriptingManager *m = lrg_scripting_manager_get_default ();
  guint n = 0;
  g_autofree LrgScriptLanguage *a = lrg_scripting_manager_get_available (m, &n);
  return (gint) n;
}

gint
cmacs_libregnum_scripting_language_at (gint index)
{
  LrgScriptingManager *m = lrg_scripting_manager_get_default ();
  guint n = 0;
  g_autofree LrgScriptLanguage *a = lrg_scripting_manager_get_available (m, &n);
  if (index < 0 || (guint) index >= n)
    return -1;
  return (gint) a[index];
}

char *
cmacs_libregnum_scripting_language_name (gint index)
{
  LrgScriptingManager *m = lrg_scripting_manager_get_default ();
  guint n = 0;
  g_autofree LrgScriptLanguage *a = lrg_scripting_manager_get_available (m, &n);
  if (index < 0 || (guint) index >= n)
    return NULL;
  return g_strdup (lrg_scripting_manager_get_display_name (m, a[index]));
}

/* ── Project + asset database ──────────────────────────────────────── */

/* Create + save a project manifest (project.ryaml) under ROOT. */
gboolean
cmacs_libregnum_project_create (const char *root, const char *name,
                                const char *default_level,
                                const char *game_output)
{
  g_autoptr (LrgProject) p = NULL;
  g_autoptr (GError) error = NULL;
  if (!root)
    return FALSE;
  p = lrg_project_new (root, name);
  if (default_level)
    lrg_project_set_default_level (p, default_level);
  if (game_output)
    lrg_project_set_game_output (p, game_output);
  lrg_project_add_asset_dir (p, "assets");
  return lrg_project_save (p, &error);
}

/* Open the project at ROOT and load its default level into the editor. */
gboolean
cmacs_libregnum_render_ctx_editor_open_project (CmacsLibregnumRenderCtx *r,
                                                const char *root)
{
  g_autoptr (LrgProject) p = NULL;
  g_autoptr (GError) error = NULL;
  const char *lvl;
  g_autofree char *path = NULL;
  if (!r || !r->editor || !root)
    return FALSE;
  p = lrg_project_open (root, &error);
  if (!p)
    return FALSE;
  lvl = lrg_project_get_default_level (p);
  if (!lvl || !lvl[0])
    return FALSE;
  path = g_build_filename (root, lvl, NULL);
  if (!lrg_editor_load_level (r->editor, path, &error))
    return FALSE;
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* Scan DIR into a fresh LrgAssetDatabase (returned as an owned void*). */
void *
cmacs_libregnum_assetdb_scan (const char *dir)
{
  LrgAssetDatabase *db;
  g_autoptr (GError) error = NULL;
  if (!dir)
    return NULL;
  db = lrg_asset_database_new ();
  lrg_asset_database_add_search_dir (db, dir);
  lrg_asset_database_scan (db, &error);
  return db;
}

gint
cmacs_libregnum_assetdb_count (void *db)
{
  return db ? (gint) lrg_asset_database_get_count (LRG_ASSET_DATABASE (db)) : 0;
}

/* FIELD: 0 path, 1 name, 2 guid -> newly-allocated string (caller frees). */
char *
cmacs_libregnum_assetdb_entry (void *db, gint index, gint field)
{
  LrgAssetEntry *e;
  if (!db)
    return NULL;
  e = lrg_asset_database_get_entry (LRG_ASSET_DATABASE (db), (guint) index);
  if (!e)
    return NULL;
  switch (field)
    {
    case 1:  return g_strdup (lrg_asset_entry_get_name (e));
    case 2:  return g_strdup (lrg_asset_entry_get_guid (e));
    default: return g_strdup (lrg_asset_entry_get_path (e));
    }
}

gint
cmacs_libregnum_assetdb_entry_type (void *db, gint index)
{
  LrgAssetEntry *e;
  if (!db)
    return 0;
  e = lrg_asset_database_get_entry (LRG_ASSET_DATABASE (db), (guint) index);
  return e ? (gint) lrg_asset_entry_get_asset_type (e) : 0;
}

void
cmacs_libregnum_assetdb_free (void *db)
{
  if (db)
    g_object_unref (db);
}

/* Set a numeric visual param on node ID (e.g. light "range"/"r"/"g"/"b",
 * camera "fov", audio "range") + rebuild so the gizmos reflect it. */
void
cmacs_libregnum_render_ctx_editor_set_visual_param (CmacsLibregnumRenderCtx *r,
                                                    gint id, const char *name,
                                                    double value)
{
  LrgNode       *n = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  if (!n || !name) return;
  vis = lrg_node_get_visual (n);
  if (!vis) return;
  lrg_node_visual_set_param_double (vis, name, value);
  cmacs_editor_rebuild (r);
}

/* Return node ID's visual asset path (sound file / mesh / sprite / tileset) as
 * a newly-allocated string, or NULL. */
char *
cmacs_libregnum_render_ctx_editor_node_asset (CmacsLibregnumRenderCtx *r,
                                              gint id)
{
  LrgNode       *n = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  const char    *asset;
  if (!n) return NULL;
  vis = lrg_node_get_visual (n);
  if (!vis) return NULL;
  asset = lrg_node_visual_get_asset (vis);
  return (asset && asset[0]) ? g_strdup (asset) : NULL;
}

/* Return node ID's visual kind (LrgNodeVisualKind int), or -1 if the node has
 * no visual (a group/transform node) or does not exist.  The Lisp layer maps
 * the int to a menu node-kind symbol so the context menu can vary per kind. */
gint
cmacs_libregnum_render_ctx_editor_node_kind (CmacsLibregnumRenderCtx *r, gint id)
{
  LrgNode       *n = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis = n ? lrg_node_get_visual (n) : NULL;
  return vis ? (gint) lrg_node_visual_get_kind (vis) : -1;
}

/* Return node ID's LrgPrimitiveType int when it is a primitive shape, else -1.
 * Lets the outliner show the concrete shape ("Cube") as a type label that is
 * independent of the node's (renameable) name. */
gint
cmacs_libregnum_render_ctx_editor_node_primitive (CmacsLibregnumRenderCtx *r,
                                                  gint id)
{
  LrgNode       *n = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis = n ? lrg_node_get_visual (n) : NULL;
  if (!vis || lrg_node_visual_get_kind (vis) != LRG_NODE_VISUAL_PRIMITIVE)
    return -1;
  return (gint) lrg_node_visual_get_primitive (vis);
}

/* Rename node ID and re-bake so the new name shows everywhere the baked node
 * model is read (the outliner labels via cmacs-libregnum-tree-nodes cache the
 * name at bake time, so a plain GObject set would not refresh them). */
void
cmacs_libregnum_render_ctx_editor_set_name (CmacsLibregnumRenderCtx *r,
                                            gint id, const char *name)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  if (!n) return;
  lrg_node_set_name (n, name ? name : "");
  cmacs_editor_rebuild (r);
}

/* ── Material / color API ───────────────────────────────────────────── */

/* Set or create a material on NODE_ID's visual and apply the given color. */
gboolean
cmacs_libregnum_render_ctx_editor_set_color (CmacsLibregnumRenderCtx *r,
                                             gint id,
                                             float fr, float fg,
                                             float fb, float fa)
{
  LrgNode      *n   = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  LrgMaterial3D *mat;
  if (!n || !r->editor) return FALSE;
  vis = lrg_node_get_visual (n);
  if (!vis) return FALSE;
  mat = lrg_node_visual_get_material (vis);
  if (!mat)
    {
      mat = lrg_material3d_new_with_color (fr, fg, fb, fa);
      lrg_node_visual_set_material (vis, mat);
      g_object_unref (mat);
    }
  else
    lrg_material3d_set_color (mat, fr, fg, fb, fa);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* Get the material color of NODE_ID's visual; return FALSE if no material. */
gboolean
cmacs_libregnum_render_ctx_editor_node_color (CmacsLibregnumRenderCtx *r,
                                              gint id,
                                              float *fr, float *fg,
                                              float *fb, float *fa)
{
  LrgNode       *n   = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  LrgMaterial3D *mat;
  if (!n) return FALSE;
  vis = lrg_node_get_visual (n);
  if (!vis) return FALSE;
  mat = lrg_node_visual_get_material (vis);
  if (!mat) return FALSE;
  lrg_material3d_get_color (mat, fr, fg, fb, fa);
  return TRUE;
}

/* Set the roughness of NODE_ID's material. */
gboolean
cmacs_libregnum_render_ctx_editor_set_roughness (CmacsLibregnumRenderCtx *r,
                                                 gint id, float v)
{
  LrgNode       *n   = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  LrgMaterial3D *mat;
  if (!n || !r->editor) return FALSE;
  vis = lrg_node_get_visual (n);
  if (!vis) return FALSE;
  mat = lrg_node_visual_get_material (vis);
  if (!mat)
    {
      mat = lrg_material3d_new ();
      lrg_node_visual_set_material (vis, mat);
      g_object_unref (mat);
      mat = lrg_node_visual_get_material (vis);
    }
  lrg_material3d_set_roughness (mat, v);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* Set the metallic of NODE_ID's material. */
gboolean
cmacs_libregnum_render_ctx_editor_set_metallic (CmacsLibregnumRenderCtx *r,
                                                gint id, float v)
{
  LrgNode       *n   = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  LrgMaterial3D *mat;
  if (!n || !r->editor) return FALSE;
  vis = lrg_node_get_visual (n);
  if (!vis) return FALSE;
  mat = lrg_node_visual_get_material (vis);
  if (!mat)
    {
      mat = lrg_material3d_new ();
      lrg_node_visual_set_material (vis, mat);
      g_object_unref (mat);
      mat = lrg_node_visual_get_material (vis);
    }
  lrg_material3d_set_metallic (mat, v);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* ── Clone / hierarchy ──────────────────────────────────────────────── */

/* Deep-clone NODE_ID under its current parent; return the new node id. */
gint
cmacs_libregnum_render_ctx_editor_duplicate_node (CmacsLibregnumRenderCtx *r,
                                                  gint id)
{
  LrgNode *n      = cmacs_editor_node_for_id (r, id);
  LrgNode *parent;
  LrgNode *clone;
  LrgNode *sel;
  if (!n || !r->editor) return -1;
  parent = lrg_node_get_parent (n);
  clone  = lrg_prefab_clone (n);   /* transfer full; parentless */
  lrg_editor_add_node (r->editor, clone, parent);
  g_object_unref (clone);
  cmacs_editor_rebuild (r);
  sel = lrg_editor_selection_get_primary (lrg_editor_get_selection (r->editor));
  return cmacs_editor_id_for_node (r, sel);
}

/* Return the editor id of NODE_ID's parent, or -1 for the level root. */
gint
cmacs_libregnum_render_ctx_editor_node_parent (CmacsLibregnumRenderCtx *r,
                                               gint id)
{
  LrgNode *n      = cmacs_editor_node_for_id (r, id);
  LrgNode *parent;
  if (!n) return -1;
  parent = lrg_node_get_parent (n);
  if (!parent) return -1;
  /* The root node itself is the direct child of the level: if the parent is
   * not in the baked map it is the invisible level root. */
  return cmacs_editor_id_for_node (r, parent);
}

/* Add an empty group node under PARENT_ID (-1 = level root). */
gint
cmacs_libregnum_render_ctx_editor_add_empty (CmacsLibregnumRenderCtx *r,
                                             const char *name,
                                             gint parent_id)
{
  LrgNode *node;
  LrgNode *parent;
  LrgNode *sel;
  if (!r || !r->editor) return -1;
  node   = lrg_node_new (name ? name : "Group");
  parent = (parent_id >= 0) ? cmacs_editor_node_for_id (r, parent_id) : NULL;
  lrg_editor_add_node (r->editor, node, parent);
  g_object_unref (node);
  cmacs_editor_rebuild (r);
  sel = lrg_editor_selection_get_primary (lrg_editor_get_selection (r->editor));
  return cmacs_editor_id_for_node (r, sel);
}

/* ── Scripts ────────────────────────────────────────────────────────── */

/* Return the number of script bindings on NODE_ID.  (Same as the existing
 * node_script_count but defined here for symmetry with detach below.) */

/* Detach the INDEXth script binding from NODE_ID. */
gboolean
cmacs_libregnum_render_ctx_editor_detach_script (CmacsLibregnumRenderCtx *r,
                                                 gint id, gint index)
{
  LrgNode   *n = cmacs_editor_node_for_id (r, id);
  GPtrArray *s;
  if (!n || !r->editor) return FALSE;
  s = lrg_node_get_scripts (n);
  if (!s || index < 0 || (guint) index >= s->len) return FALSE;
  g_ptr_array_remove_index (s, (guint) index);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* Return the script bindings of NODE_ID as a list (language, path, enabled)
 * triples.  Caller uses the returned GPtrArray directly (borrowed); the
 * calling DEFUN iterates and builds Lisp. */
GPtrArray *
cmacs_libregnum_render_ctx_editor_node_scripts (CmacsLibregnumRenderCtx *r,
                                                gint id)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  if (!n) return NULL;
  return lrg_node_get_scripts (n);
}

/* ── Asset ──────────────────────────────────────────────────────────── */

/* Set NODE_ID's visual asset path. */
gboolean
cmacs_libregnum_render_ctx_editor_set_node_asset (CmacsLibregnumRenderCtx *r,
                                                  gint id, const char *asset)
{
  LrgNode       *n   = cmacs_editor_node_for_id (r, id);
  LrgNodeVisual *vis;
  if (!n || !r->editor) return FALSE;
  vis = lrg_node_get_visual (n);
  if (!vis) return FALSE;
  lrg_node_visual_set_asset (vis, asset);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* ── Unpack prefab ──────────────────────────────────────────────────── */

/* Strip the visual from NODE_ID, leaving a plain group. */
gboolean
cmacs_libregnum_render_ctx_editor_unpack_prefab (CmacsLibregnumRenderCtx *r,
                                                 gint id)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  if (!n || !r->editor) return FALSE;
  lrg_node_set_visual (n, NULL);
  cmacs_editor_rebuild (r);
  return TRUE;
}

/* ── Multi-select ───────────────────────────────────────────────────── */

/* Add NODE_ID to the engine selection (additive). */
gboolean
cmacs_libregnum_render_ctx_editor_select_add (CmacsLibregnumRenderCtx *r,
                                              gint id)
{
  LrgNode            *n   = cmacs_editor_node_for_id (r, id);
  LrgEditorSelection *sel;
  if (!n || !r->editor) return FALSE;
  sel = lrg_editor_get_selection (r->editor);
  lrg_editor_selection_add (sel, n);
  /* Keep r->selected in sync with the new primary. */
  {
    LrgNode *prim = lrg_editor_selection_get_primary (sel);
    r->selected = prim ? cmacs_editor_id_for_node (r, prim) : -1;
  }
  return TRUE;
}

/* Remove NODE_ID from the engine selection. */
gboolean
cmacs_libregnum_render_ctx_editor_select_remove (CmacsLibregnumRenderCtx *r,
                                                 gint id)
{
  LrgNode            *n   = cmacs_editor_node_for_id (r, id);
  LrgEditorSelection *sel;
  if (!n || !r->editor) return FALSE;
  sel = lrg_editor_get_selection (r->editor);
  lrg_editor_selection_remove (sel, n);
  {
    LrgNode *prim = lrg_editor_selection_get_primary (sel);
    r->selected = prim ? cmacs_editor_id_for_node (r, prim) : -1;
  }
  return TRUE;
}

/* Clear the entire engine selection. */
void
cmacs_libregnum_render_ctx_editor_select_clear (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->editor) return;
  lrg_editor_selection_clear (lrg_editor_get_selection (r->editor));
  r->selected = -1;
}

/* Return the selected node ids from the engine selection as a GArray of gint.
 * Transfer-full; caller g_array_unref(). */
GArray *
cmacs_libregnum_render_ctx_editor_selected_ids (CmacsLibregnumRenderCtx *r)
{
  GArray             *out;
  LrgEditorSelection *sel;
  GPtrArray          *nodes;
  guint               i;
  out = g_array_new (FALSE, FALSE, sizeof (gint));
  if (!r || !r->editor) return out;
  sel   = lrg_editor_get_selection (r->editor);
  nodes = lrg_editor_selection_get_nodes (sel);
  if (!nodes) return out;
  for (i = 0; i < nodes->len; i++)
    {
      gint nid = cmacs_editor_id_for_node (r,
                   (LrgNode *) g_ptr_array_index (nodes, i));
      if (nid >= 0)
        g_array_append_val (out, nid);
    }
  return out;
}

/* ── Feature 1: real-time scene shading ─────────────────────────────── */

/* Enable or disable Blinn-Phong shading.  On first enable the shader +
 * material are lazily created.  Attached/detached to all baked
 * MESH_ASSET models immediately; future rebuilds re-attach automatically
 * (see cmacs_editor_rebuild). */
void
cmacs_libregnum_render_ctx_editor_set_shading (CmacsLibregnumRenderCtx *r,
                                                gboolean on)
{
  if (!r || !r->editor) return;
  if (on)
    ctx_ensure_lighting_shader (r);
  ctx_attach_shading_materials (r, on);
  r->shading = on;
}

gboolean
cmacs_libregnum_render_ctx_editor_shading_p (CmacsLibregnumRenderCtx *r)
{
  if (!r) return FALSE;
  return r->shading;
}

/* ── Feature 2: look-through camera ─────────────────────────────────── */

/* Drive the viewport camera from the CAMERA node at `id'.
 * Returns FALSE if `id' is out of range or not a CAMERA node. */
gboolean
cmacs_libregnum_render_ctx_editor_look_through (CmacsLibregnumRenderCtx *r,
                                                 gint id)
{
  LrgNode       *ln;
  LrgNodeVisual *lv;
  if (!r || !r->editor_node_map) return FALSE;
  if (id < 0 || (guint) id >= r->editor_node_map->len) return FALSE;
  ln = g_ptr_array_index (r->editor_node_map, id);
  if (!ln) return FALSE;
  lv = lrg_node_get_visual (ln);
  if (!lv || lrg_node_visual_get_kind (lv) != LRG_NODE_VISUAL_CAMERA)
    return FALSE;
  r->camera_lookthrough    = TRUE;
  r->camera_lookthrough_id = id;
  return TRUE;
}

/* Cancel look-through and return to orbit camera. */
void
cmacs_libregnum_render_ctx_editor_look_through_off (CmacsLibregnumRenderCtx *r)
{
  if (!r) return;
  r->camera_lookthrough    = FALSE;
  r->camera_lookthrough_id = -1;
}

/* Returns the look-through node id, or -1 if not active. */
gint
cmacs_libregnum_render_ctx_editor_look_through_p (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->camera_lookthrough) return -1;
  return r->camera_lookthrough_id;
}

/* ── Feature 3: per-node visual param read-back ─────────────────────── */

/* Return the named visual param for node `id' as a double.
 * Returns `def' if the id is invalid, the node has no visual, or the
 * param is not set. */
double
cmacs_libregnum_render_ctx_editor_get_visual_param (CmacsLibregnumRenderCtx *r,
                                                     gint id,
                                                     const char *name,
                                                     double def)
{
  LrgNode       *ln;
  LrgNodeVisual *lv;
  if (!r || !r->editor_node_map) return def;
  if (id < 0 || (guint) id >= r->editor_node_map->len) return def;
  ln = g_ptr_array_index (r->editor_node_map, id);
  if (!ln) return def;
  lv = lrg_node_get_visual (ln);
  if (!lv) return def;
  return lrg_node_visual_get_param_double (lv, name, def);
}

#else /* !LRG_BUILD_EDITOR -- stubs so the Lisp layer still links */

gboolean cmacs_libregnum_render_ctx_editor_new (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_open (CmacsLibregnumRenderCtx *r,
         const char *path, char **error_msg)
{ (void) r; (void) path; if (error_msg) *error_msg = g_strdup ("editor not built"); return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_save (CmacsLibregnumRenderCtx *r,
         const char *path, char **error_msg)
{ (void) r; (void) path; if (error_msg) *error_msg = g_strdup ("editor not built"); return FALSE; }
void cmacs_libregnum_render_ctx_editor_close (CmacsLibregnumRenderCtx *r) { (void) r; }
gboolean cmacs_libregnum_render_ctx_editor_active (CmacsLibregnumRenderCtx *r) { (void) r; return FALSE; }
gint cmacs_libregnum_render_ctx_editor_add_primitive (CmacsLibregnumRenderCtx *r,
         int prim, const char *name) { (void) r; (void) prim; (void) name; return -1; }
void cmacs_libregnum_render_ctx_editor_delete (CmacsLibregnumRenderCtx *r, gint id) { (void) r; (void) id; }
void cmacs_libregnum_render_ctx_editor_select_node (CmacsLibregnumRenderCtx *r, gint id) { (void) r; (void) id; }
void cmacs_libregnum_render_ctx_editor_set_position (CmacsLibregnumRenderCtx *r, gint id,
         double x, double y, double z) { (void) r; (void) id; (void) x; (void) y; (void) z; }
void cmacs_libregnum_render_ctx_editor_undo (CmacsLibregnumRenderCtx *r) { (void) r; }
void cmacs_libregnum_render_ctx_editor_redo (CmacsLibregnumRenderCtx *r) { (void) r; }
gboolean cmacs_libregnum_render_ctx_editor_can_undo (CmacsLibregnumRenderCtx *r) { (void) r; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_can_redo (CmacsLibregnumRenderCtx *r) { (void) r; return FALSE; }
const char *cmacs_libregnum_render_ctx_editor_node_guid (CmacsLibregnumRenderCtx *r, gint id)
{ (void) r; (void) id; return NULL; }
gboolean cmacs_libregnum_render_ctx_editor_node_location (CmacsLibregnumRenderCtx *r,
         gint id, double *x, double *y, double *z)
{ (void) r; (void) id; (void) x; (void) y; (void) z; return FALSE; }
void cmacs_libregnum_render_ctx_editor_set_snap (CmacsLibregnumRenderCtx *r, double snap)
{ (void) r; (void) snap; }
gboolean cmacs_libregnum_render_ctx_editor_dragging (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_drag_begin (CmacsLibregnumRenderCtx *r,
         gint id, double vx, double vy, int vw, int vh)
{ (void) r; (void) id; (void) vx; (void) vy; (void) vw; (void) vh; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_drag_update (CmacsLibregnumRenderCtx *r,
         double vx, double vy, int vw, int vh)
{ (void) r; (void) vx; (void) vy; (void) vw; (void) vh; return FALSE; }
void cmacs_libregnum_render_ctx_editor_drag_end (CmacsLibregnumRenderCtx *r) { (void) r; }
gboolean cmacs_libregnum_render_ctx_editor_node_rotation (CmacsLibregnumRenderCtx *r,
         gint id, double *x, double *y, double *z)
{ (void) r; (void) id; (void) x; (void) y; (void) z; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_node_scale (CmacsLibregnumRenderCtx *r,
         gint id, double *x, double *y, double *z)
{ (void) r; (void) id; (void) x; (void) y; (void) z; return FALSE; }
void cmacs_libregnum_render_ctx_editor_set_rotation (CmacsLibregnumRenderCtx *r,
         gint id, double x, double y, double z)
{ (void) r; (void) id; (void) x; (void) y; (void) z; }
void cmacs_libregnum_render_ctx_editor_set_scale (CmacsLibregnumRenderCtx *r,
         gint id, double x, double y, double z)
{ (void) r; (void) id; (void) x; (void) y; (void) z; }
gboolean cmacs_libregnum_render_ctx_editor_reparent (CmacsLibregnumRenderCtx *r,
         gint child_id, gint parent_id)
{ (void) r; (void) child_id; (void) parent_id; return FALSE; }
gint cmacs_libregnum_render_ctx_editor_add_visual (CmacsLibregnumRenderCtx *r,
         int kind, const char *asset, const char *name)
{ (void) r; (void) kind; (void) asset; (void) name; return -1; }
gboolean cmacs_libregnum_render_ctx_editor_attach_script (CmacsLibregnumRenderCtx *r,
         gint id, int language, const char *path)
{ (void) r; (void) id; (void) language; (void) path; return FALSE; }
gint cmacs_libregnum_render_ctx_editor_node_script_count (CmacsLibregnumRenderCtx *r,
         gint id) { (void) r; (void) id; return -1; }
gboolean cmacs_libregnum_render_ctx_editor_play (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
void cmacs_libregnum_render_ctx_editor_stop (CmacsLibregnumRenderCtx *r) { (void) r; }
gboolean cmacs_libregnum_render_ctx_editor_playing (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_play_tick (CmacsLibregnumRenderCtx *r,
         double delta) { (void) r; (void) delta; return FALSE; }
void cmacs_libregnum_render_ctx_editor_set_tool (CmacsLibregnumRenderCtx *r, int tool)
{ (void) r; (void) tool; }
gint cmacs_libregnum_render_ctx_editor_get_tool (CmacsLibregnumRenderCtx *r)
{ (void) r; return 0; }
gboolean cmacs_libregnum_render_ctx_editor_gizmo_active (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_gizmo_hit (CmacsLibregnumRenderCtx *r,
         double vx, double vy, int vw, int vh)
{ (void) r; (void) vx; (void) vy; (void) vw; (void) vh; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_gizmo_begin (CmacsLibregnumRenderCtx *r,
         double vx, double vy, int vw, int vh)
{ (void) r; (void) vx; (void) vy; (void) vw; (void) vh; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_gizmo_drag (CmacsLibregnumRenderCtx *r,
         double vx, double vy, int vw, int vh)
{ (void) r; (void) vx; (void) vy; (void) vw; (void) vh; return FALSE; }
void cmacs_libregnum_render_ctx_editor_gizmo_end (CmacsLibregnumRenderCtx *r)
{ (void) r; }
void cmacs_libregnum_render_ctx_editor_set_view_2d (CmacsLibregnumRenderCtx *r,
         gboolean on) { (void) r; (void) on; }
gboolean cmacs_libregnum_render_ctx_editor_view_2d (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
void cmacs_libregnum_render_ctx_editor_sync_play (CmacsLibregnumRenderCtx *r)
{ (void) r; }
void cmacs_libregnum_render_ctx_editor_set_armed (CmacsLibregnumRenderCtx *r,
         gboolean on) { (void) r; (void) on; }
gboolean cmacs_libregnum_render_ctx_editor_armed (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_screen_to_ground (CmacsLibregnumRenderCtx *r,
         double vx, double vy, int vw, int vh, double *x, double *y, double *z)
{ (void) r; (void) vx; (void) vy; (void) vw; (void) vh; (void) x; (void) y; (void) z; return FALSE; }
void cmacs_libregnum_render_ctx_editor_tilemap_config (CmacsLibregnumRenderCtx *r,
         gint id, const char *tileset, int tw, int th, int cols, int mw, int mh)
{ (void) r; (void) id; (void) tileset; (void) tw; (void) th; (void) cols;
  (void) mw; (void) mh; }
void cmacs_libregnum_render_ctx_editor_tilemap_set_tile (CmacsLibregnumRenderCtx *r,
         gint id, int cx, int cy, int tile)
{ (void) r; (void) id; (void) cx; (void) cy; (void) tile; }
gboolean cmacs_libregnum_render_ctx_editor_tilemap_info (CmacsLibregnumRenderCtx *r,
         gint id, int *mw, int *mh, int *cols, int *tw, int *th)
{ (void) r; (void) id; (void) mw; (void) mh; (void) cols; (void) tw; (void) th;
  return FALSE; }
void * cmacs_libregnum_render_ctx_editor_node_object (CmacsLibregnumRenderCtx *r,
         gint id)
{ (void) r; (void) id; return NULL; }
gboolean cmacs_libregnum_render_ctx_editor_save_prefab (CmacsLibregnumRenderCtx *r,
         gint id, const char *path)
{ (void) r; (void) id; (void) path; return FALSE; }
gint cmacs_libregnum_render_ctx_editor_instantiate_prefab (CmacsLibregnumRenderCtx *r,
         const char *path, gint parent_id)
{ (void) r; (void) path; (void) parent_id; return -1; }
gboolean cmacs_libregnum_render_ctx_editor_import_scene (CmacsLibregnumRenderCtx *r,
         const char *path)
{ (void) r; (void) path; return FALSE; }
gint cmacs_libregnum_scripting_language_count (void) { return 0; }
gint cmacs_libregnum_scripting_language_at (gint index) { (void) index; return -1; }
char * cmacs_libregnum_scripting_language_name (gint index)
{ (void) index; return NULL; }
gboolean cmacs_libregnum_project_create (const char *root, const char *name,
         const char *default_level, const char *game_output)
{ (void) root; (void) name; (void) default_level; (void) game_output;
  return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_open_project (CmacsLibregnumRenderCtx *r,
         const char *root)
{ (void) r; (void) root; return FALSE; }
void * cmacs_libregnum_assetdb_scan (const char *dir) { (void) dir; return NULL; }
gint cmacs_libregnum_assetdb_count (void *db) { (void) db; return 0; }
char * cmacs_libregnum_assetdb_entry (void *db, gint index, gint field)
{ (void) db; (void) index; (void) field; return NULL; }
gint cmacs_libregnum_assetdb_entry_type (void *db, gint index)
{ (void) db; (void) index; return 0; }
void cmacs_libregnum_assetdb_free (void *db) { (void) db; }
void cmacs_libregnum_render_ctx_editor_set_visual_param (CmacsLibregnumRenderCtx *r,
         gint id, const char *name, double value)
{ (void) r; (void) id; (void) name; (void) value; }
char * cmacs_libregnum_render_ctx_editor_node_asset (CmacsLibregnumRenderCtx *r,
         gint id) { (void) r; (void) id; return NULL; }
gint cmacs_libregnum_render_ctx_editor_node_kind (CmacsLibregnumRenderCtx *r,
         gint id) { (void) r; (void) id; return -1; }
gint cmacs_libregnum_render_ctx_editor_node_primitive (CmacsLibregnumRenderCtx *r,
         gint id) { (void) r; (void) id; return -1; }
void cmacs_libregnum_render_ctx_editor_set_name (CmacsLibregnumRenderCtx *r,
         gint id, const char *name) { (void) r; (void) id; (void) name; }
gboolean cmacs_libregnum_render_ctx_editor_set_color (CmacsLibregnumRenderCtx *r,
         gint id, float fr, float fg, float fb, float fa)
{ (void) r; (void) id; (void) fr; (void) fg; (void) fb; (void) fa;
  return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_node_color (CmacsLibregnumRenderCtx *r,
         gint id, float *fr, float *fg, float *fb, float *fa)
{ (void) r; (void) id; (void) fr; (void) fg; (void) fb; (void) fa;
  return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_set_roughness (CmacsLibregnumRenderCtx *r,
         gint id, float v)
{ (void) r; (void) id; (void) v; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_set_metallic (CmacsLibregnumRenderCtx *r,
         gint id, float v)
{ (void) r; (void) id; (void) v; return FALSE; }
gint cmacs_libregnum_render_ctx_editor_duplicate_node (CmacsLibregnumRenderCtx *r,
         gint id)
{ (void) r; (void) id; return -1; }
gint cmacs_libregnum_render_ctx_editor_node_parent (CmacsLibregnumRenderCtx *r,
         gint id)
{ (void) r; (void) id; return -1; }
gint cmacs_libregnum_render_ctx_editor_add_empty (CmacsLibregnumRenderCtx *r,
         const char *name, gint parent_id)
{ (void) r; (void) name; (void) parent_id; return -1; }
gboolean cmacs_libregnum_render_ctx_editor_detach_script (CmacsLibregnumRenderCtx *r,
         gint id, gint index)
{ (void) r; (void) id; (void) index; return FALSE; }
GPtrArray * cmacs_libregnum_render_ctx_editor_node_scripts (CmacsLibregnumRenderCtx *r,
         gint id)
{ (void) r; (void) id; return NULL; }
gboolean cmacs_libregnum_render_ctx_editor_set_node_asset (CmacsLibregnumRenderCtx *r,
         gint id, const char *asset)
{ (void) r; (void) id; (void) asset; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_unpack_prefab (CmacsLibregnumRenderCtx *r,
         gint id)
{ (void) r; (void) id; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_select_add (CmacsLibregnumRenderCtx *r,
         gint id)
{ (void) r; (void) id; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_select_remove (CmacsLibregnumRenderCtx *r,
         gint id)
{ (void) r; (void) id; return FALSE; }
void cmacs_libregnum_render_ctx_editor_select_clear (CmacsLibregnumRenderCtx *r)
{ (void) r; }
GArray * cmacs_libregnum_render_ctx_editor_selected_ids (CmacsLibregnumRenderCtx *r)
{ (void) r; return g_array_new (FALSE, FALSE, sizeof (gint)); }
void cmacs_libregnum_render_ctx_editor_set_shading (CmacsLibregnumRenderCtx *r,
         gboolean on) { (void) r; (void) on; }
gboolean cmacs_libregnum_render_ctx_editor_shading_p (CmacsLibregnumRenderCtx *r)
{ (void) r; return FALSE; }
gboolean cmacs_libregnum_render_ctx_editor_look_through (CmacsLibregnumRenderCtx *r,
         gint id) { (void) r; (void) id; return FALSE; }
void cmacs_libregnum_render_ctx_editor_look_through_off (CmacsLibregnumRenderCtx *r)
{ (void) r; }
gint cmacs_libregnum_render_ctx_editor_look_through_p (CmacsLibregnumRenderCtx *r)
{ (void) r; return -1; }
double cmacs_libregnum_render_ctx_editor_get_visual_param (CmacsLibregnumRenderCtx *r,
         gint id, const char *name, double def)
{ (void) r; (void) id; (void) name; return def; }

#endif /* LRG_BUILD_EDITOR */

#endif /* HAVE_CMACS_LIBREGNUM */
