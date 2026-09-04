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
#ifdef HAVE_CMACS_CAD
# define LRG_ENABLE_CAD 1   /* CMACS: expose libregnum's CAD manager */
#endif
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

/* TRUE when we BORROW the cmacs lrgterm backend's raylib window + GL context
   (under `emacs --lrg').  raylib is one-window-per-process, so opening our own
   hidden window then would deadlock; instead we render into FBOs using the
   already-current lrg context, with a windowless renderer.  */
static gboolean      shared_external_context = FALSE;

#ifdef HAVE_CMACS_LRGTERM
/* Defined in cmacs/lrgterm/cmacs-lrgterm.c.  Weak so a libregnum-only (or
   pgtk-only) build with no lrgterm objects still links -- the symbol is then
   NULL and we take the normal hidden-window path.  */
extern bool cmacs_lrgterm_active_p (void) __attribute__ ((weak));
#endif

gboolean
cmacs_libregnum_render_window_acquire (gchar **error_msg)
{
  shared_refs++;
  if (shared_window != NULL || shared_external_context) return TRUE;

#ifdef HAVE_CMACS_LRGTERM
  /* Under `emacs --lrg' the lrgterm backend already owns the one raylib
   * window + GL context.  Borrow it: do NOT open a second window (that would
   * deadlock).  ctx_new then renders into FBOs with a windowless renderer
   * using the lrg context, which stays current on the main thread. */
  if (cmacs_lrgterm_active_p != NULL && cmacs_lrgterm_active_p ())
    {
      shared_external_context = TRUE;
      return TRUE;
    }
#endif

  /* Create the hidden window + engine exactly once and keep them resident
   * for the process lifetime.  raylib cannot reliably re-create its GL
   * context / FBOs after a CloseWindow + later InitWindow cycle
   * (LoadRenderTexture then fails with "Framebuffer object can not be
   * created"), so once the context exists we reuse it -- views come and go
   * but the shared window does not (see ..._window_release). */

  SetTraceLogLevel (LOG_WARNING);
  SetConfigFlags (FLAG_WINDOW_HIDDEN);

  shared_window = lrg_grl_window_new (1, 1, "cmacs-libregnum-hidden");
  /* IsWindowReady() is false when GLFW could not bring up a GL context (e.g. no
     X DISPLAY -- graylib now pre-flights glfwInit and skips InitWindow instead
     of crashing).  Bail cleanly here rather than proceeding into engine/GL setup
     with no context. */
  if (!shared_window || !IsWindowReady ())
    {
      if (error_msg)
        *error_msg = g_strdup ("cmacs-libregnum: no GL display available -- "
                               "libregnum views need an X DISPLAY (run under "
                               "`emacs --lrg' or a graphical X/XWayland session)");
      g_clear_object (&shared_window);
      shared_refs = 0;
      return FALSE;
    }

  shared_engine = lrg_engine_get_default ();
  lrg_engine_set_window (shared_engine, LRG_WINDOW (shared_window));

  /* Extend the projection far cull plane (default 1000) so the gnuseye
   * solar-system chart -- linearly true distances at 290 units/AU, Neptune
   * ~8700 out -- renders without clipping.  Depth precision near the globe
   * stays ample (near plane 0.01).  Runtime API, raylib >= 5.5. */
  rlSetClipPlanes (0.01, 20000.0);

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
  guint    flags;         /* CmacsLibregnumNodeFlags */
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
  guint32     rgba;      /* tint; 0 means opaque white */
  GrlTexture *tex;       /* owned */
  guint8      layer;     /* 0 = alpha-blended, depth-sorted;
                            1 = additive glow, drawn after, unsorted */
} CmacsBillboard;

/* Draw-order entry for the sorted billboard pass. */
typedef struct
{
  float key;             /* squared distance to the camera */
  guint idx;
} CmacsBillboardOrder;

/* Farther first: alpha-blended quads must draw back-to-front, or a
   near quad's translucent texels write depth and clip every quad
   behind them into rectangles. */
static int
cmacs_billboard_order_cmp (const void *pa, const void *pb)
{
  const CmacsBillboardOrder *a = pa;
  const CmacsBillboardOrder *b = pb;

  if (a->key > b->key) return -1;
  if (a->key < b->key) return 1;
  return 0;
}

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
  float       cx, cy, cz;      /* model-space pivot (the geometry's local AABB
                                  centre); rotation spins about this so a part
                                  modelled off its origin turns IN PLACE rather
                                  than orbiting the origin.  0 for primitives
                                  (already centred on their node). */
  guint8      cr, cg, cb;
  gint        node_id;          /* baked scene node id (for wireframe param) */
} CmacsEditorModel;
#endif

/* A persistent positioned textured model (gnuseye celestial body). */
typedef struct
{
  gchar    *key;
  GrlModel *model;     /* owned */
  double    x, y, z;
} BodyModel;

static void
body_model_free (gpointer p)
{
  BodyModel *b = p;
  g_free (b->key);
  g_clear_object (&b->model);
  g_free (b);
}

/* A translucent overlay shell (gnuseye weather: radar/cloud drapes). */
typedef struct
{
  gchar    *key;
  GrlModel *model;      /* owned */
  gfloat    alpha;      /* 0..1, applied via the draw tint */
  gboolean  enabled;
  gfloat    sort_key;   /* shell radius scale; ascending draw order */
} CmacsOverlayModel;

static void
overlay_model_free (gpointer p)
{
  CmacsOverlayModel *o = p;
  g_free (o->key);
  g_clear_object (&o->model);
  g_free (o);
}

/* One clip block on the in-viewport timeline strip. */
typedef struct
{
  int    id;                    /* clip id (for hit-test → editor ops) */
  int    track, start, dur;
  guint8 r, g, b;
} CmacsTimelineClip;

struct CmacsLibregnumRenderCtx
{
  LrgRenderer    *renderer;
  LrgCamera      *camera;
  /* Flat list of drawables (LrgDrawable*); each scene builder adds
   * primitives here.  Owned ref per element. */
  GPtrArray      *drawables;
  RenderTexture2D fbo;
  gboolean        fbo_valid;
  GrlTexture     *fbo_grl_texture;  /* non-owning wrapper of fbo.texture for
                                       the lrg overlay blit; lazily created,
                                       dropped on resize/free */
  int             width, height;

  /* ── 2D image-display mode (imgedit / vidstudio live viewport) ────────
   * When image_mode is TRUE, render_to_bgra draws a checkerboard + a
   * pan/zoomed textured quad of the composited image + a 2D overlay,
   * instead of the 3D scene (mirrors the game_mode early-return branch).
   * All GPU work happens at frame top inside BeginTextureMode where the
   * shared GL context is current; DEFUNs only stash a source + request a
   * redraw (the deferred-upload discipline the gnuseye weather overlay uses). */
  gboolean      image_mode;
  GrlTexture   *image_tex;          /* owned; doc-sized RGBA8, POINT filter */
  int           image_doc_w, image_doc_h;   /* logical doc size (set at bind) */
  int           image_tex_w, image_tex_h;   /* actual texture size (at upload) */
  /* Pending upload, consumed at frame top.  At most one source is set:
   * image_doc (borrowed LrgImageDocument*, re-flattened) OR image_pending
   * (owned GrlImage ref) OR image_rgba (owned raw RGBA8 copy). */
  gboolean      image_upload_pending;
  void         *image_doc;          /* borrowed LrgImageDocument*, or NULL */
  GrlImage     *image_pending;      /* owned ref, or NULL */
  guint8       *image_rgba;         /* owned copy, or NULL */
  int           image_rgba_w, image_rgba_h;
  /* Pan/zoom: doc pixel (dx,dy) -> FBO pixel (pan_x + dx*scale, ...). */
  double        image_scale, image_pan_x, image_pan_y;
  /* Overlay params (doc coords unless noted). */
  gboolean      image_checker, image_grid;
  double        image_cursor_x, image_cursor_y, image_cursor_r; /* <0 hides */
  gboolean      image_marquee_on;
  int           image_mx, image_my, image_mw, image_mh;
  /* Optional timeline strip (vidstudio): clip blocks + playhead drawn along
   * the bottom of the FBO.  image_clips holds CmacsTimelineClip records. */
  GArray       *image_clips;
  int           image_playhead, image_total_frames, image_ntracks;

  /* ── Text labels ─────────────────────────────────────────────────────
   * One font, shared by the vidstudio timeline overlay (which introduced
   * it) and the in-scene node-label pass.  NULL falls back to raylib's
   * built-in 10px bitmap font, which is fine for a debug HUD and much
   * too ragged for anything a user reads.
   *
   * inscene_labels moves node labels OUT of the pgtk-only cairo overlay
   * and INTO the FBO, so `emacs --lrg' gets them too: both backends
   * funnel through render_to_bgra (DST==NULL for the lrg FBO-only path),
   * so one code path serves both.  Contexts that leave it FALSE keep the
   * legacy cairo overlay untouched. */
  GrlFont      *label_font;        /* owned, or NULL for the default */
  gboolean      inscene_labels;
  gboolean      orbit_locked;    /* flat views must stay flat */
  gboolean      right_drag_pans; /* else right-drag orbits (CAD profile) */
  gboolean      wheel_up_zooms_in; /* else the legacy inverted wheel */
  gboolean      label_backdrop;  /* translucent plate behind label text */
  gboolean      emphasis_rings;  /* screen-space rings on sel/hover/match */
  int           selection_style; /* CmacsLibregnumSelectionStyle */
  int           label_px;          /* 0 = pick from the font baking size */
  gboolean      label_shadow;
  gboolean      label_declutter;
  int           label_max;         /* cap on labels drawn per frame */

  /* ── 2D chart mode (cmacs-calculator) ────────────────────────────────
   * When chart_mode is TRUE, render_to_bgra draws an LrgChart widget
   * instead of the 3D scene -- the same shape as image_mode above.  The
   * chart is an LrgWidget drawn with immediate-mode grl_draw_* calls, so
   * it must be drawn inside the BeginTextureMode bracket at frame top and
   * the rlgl batch flushed before any readback; see ctx_render_chart.
   * The widget itself is built and populated by cmacs/calculator/, which
   * owns the LrgChart subclass choice and the data series; this ctx only
   * sizes and draws it. */
  gboolean      chart_mode;
  void         *chart;             /* owned LrgChart* ref, or NULL */
  gboolean      chart_bg_set;      /* FALSE -> use the default clear colour */
  guint8        chart_bg_r, chart_bg_g, chart_bg_b, chart_bg_a;

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
  LrgGameTemplate  *game;          /* borrowed from loaded_game, unless game_owned */
  gboolean          game_owned;    /* TRUE when `game' is owned directly (no .so;
                                      e.g. the cmacs-lrgscript elisp game) */
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

  /* When > 0 the camera is orbiting an OFF-ORIGIN focus (a selected
   * celestial body): zoom becomes proportional to the distance to the
   * TARGET with this floor, instead of to the altitude above the origin
   * sphere.  Reset to 0 whenever the camera is re-aimed at the globe
   * (gnuseye camera_goto / home / deselect). */
  double            focus_min_dist;

  /* Persistent static drawables (e.g. the gnuseye coastline overlay):
   * drawn every frame after the background model and NOT cleared by
   * clear_drawables.  Owned (g_object_unref per element). */
  GPtrArray        *static_drawables;

  /* Positioned textured models that persist across marker rebuilds (the
   * gnuseye celestial bodies: textured planet spheres).  Keyed BodyModel
   * entries, drawn right after the background model.  Owned. */
  GPtrArray        *body_models;

  /* Translucent overlay shells (gnuseye weather: radar/cloud drapes).
   * Keyed CmacsOverlayModel entries drawn after the body models, BEFORE
   * the polygon models, alpha-blended with depth writes DISABLED (see the
   * draw block).  Lazily created; owned. */
  GPtrArray        *overlay_models;

  /* Filled translucent polygon models (GrlModel*) draped on the globe:
   * `polygon_models' is per-tick (alert zones), `static_polygon_models' is
   * persistent (choropleth/aurora).  Owned (g_object_unref per element). */
  GPtrArray        *polygon_models;
  GPtrArray        *static_polygon_models;

  /* Persistent map labels (country/region names), drawn by the overlay. */
  GArray           *map_labels;       /* CmacsMapLabel */

  /* Persistent camera-facing billboards (e.g. country flags). */
  GArray           *billboards;       /* CmacsBillboard */
  /* Shared lit-sphere impostor texture; see orb_texture(). */
  GrlTexture       *orb_tex;          /* owned */
  /* Shared radial-falloff glow texture; see ctx_glow_texture(). */
  GrlTexture       *glow_tex;         /* owned */

  /* Particles.  Created lazily -- a view that never asks pays
   * nothing -- and stepped inside the 3D pass, which is the only
   * place with a live camera and an open FBO. */
  /* Focus policy (see the header).  Defaults preserve the historical
   * behaviour: click flies the camera, no scene-scale floor. */
  gboolean           click_focus;
  double             focus_context;
  gboolean           drag_nodes;

  /* Background layer (see the header).  `bg_tex' is regenerated only
   * when the kind, colours, path or viewport size change. */
  CmacsLibregnumBackgroundKind bg_kind;
  guint32            bg_top, bg_bottom;
  char              *bg_path;
  Texture2D          bg_tex;
  gboolean           bg_tex_ok;
  int                bg_tex_w, bg_tex_h;
  gboolean           bg_dirty;
  CmacsLibregnumFrameSource bg_src;
  gpointer           bg_src_data;
  GDestroyNotify     bg_src_notify;
  unsigned long long bg_src_gen;       /* last frame uploaded */
  gboolean           bg_src_have;      /* a frame has been uploaded */
  guint32           *bg_src_rgba;      /* BGRA->RGBA swizzle scratch */
  gsize              bg_src_rgba_n;    /* its capacity, in pixels */

  LrgParticlePool   *particle_pool;    /* every live particle */
  GArray            *particle_emitters;/* LrgParticleEmitter *, owned */
  LrgParticleEmitter *burst_emitter;   /* owned; re-tuned per burst */
  Texture2D          particle_tex;     /* soft dot, generated once */
  gboolean           particle_tex_ok;
  gboolean           particles_on;
  gint64             particles_last_us;

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
  /* A camera-anchored key+fill rig synthesised each frame when `headlight'
   * is TRUE, so a model-only scene (CAD viewer, no LIGHT nodes) still
   * shades by surface orientation instead of rendering flat / washed-out.
   * `edges' overlays the model's wireframe in a dark tint (shaded-with-
   * edges) for crisp geometry reading. */
  gboolean          headlight;         /* TRUE = synthesise studio lights */
  gboolean          edges;             /* TRUE = draw edge overlay */

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
  if (!shared_window && !shared_external_context) return NULL;
  CmacsLibregnumRenderCtx *r = g_new0 (CmacsLibregnumRenderCtx, 1);
  r->width  = w;
  r->height = h;
  r->selected = -1;
  r->hovered = -1;
  /* Legacy defaults: existing scenes keep the wireframe box and plain
     labels until a caller asks for something else. */
  r->selection_style = CMACS_LIBREGNUM_SELECTION_BOX;
  /* With a borrowed lrg context there is no LrgWindow object; a windowless
   * renderer is fine because render_to_bgra drives BeginTextureMode/Clear
   * itself and lrg_renderer_begin_frame/end_frame/clear are no-ops when the
   * window is NULL.  (lrg_renderer_new rejects NULL, so construct directly.) */
  r->renderer  = shared_window
      ? lrg_renderer_new (LRG_WINDOW (shared_window))
      : (LrgRenderer *) g_object_new (LRG_TYPE_RENDERER, "window", NULL, NULL);
  r->drawables = g_ptr_array_new_with_free_func (g_object_unref);
  r->static_drawables = g_ptr_array_new_with_free_func (g_object_unref);
  r->body_models = g_ptr_array_new_with_free_func (body_model_free);
  r->polygon_models = g_ptr_array_new_with_free_func (g_object_unref);
  r->static_polygon_models = g_ptr_array_new_with_free_func (g_object_unref);
  r->map_labels = g_array_new (FALSE, TRUE, sizeof (CmacsMapLabel));
  g_array_set_clear_func (r->map_labels, cmacs_map_label_clear);
  /* Historical default: a click flies the camera.  A scene that is
     navigated by looking rather than by clicking turns it off. */
  r->click_focus = TRUE;
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
  /* Image-mode resources (owned; image_doc is borrowed, do not free). */
  g_clear_object (&r->image_tex);
  g_clear_object (&r->image_pending);
  g_clear_pointer (&r->image_rgba, g_free);
  if (r->image_clips) g_array_unref (r->image_clips);
  g_clear_object (&r->label_font);
  /* Chart-mode resources (owned). */
  g_clear_object ((GObject **) &r->chart);
  /* Non-owning wrapper: drop it before the FBO it points at.  */
  g_clear_object (&r->fbo_grl_texture);
  if (r->fbo_valid) UnloadRenderTexture (r->fbo);
  g_clear_object (&r->background_model);
  if (r->polygon_models) g_ptr_array_unref (r->polygon_models);
  if (r->static_polygon_models) g_ptr_array_unref (r->static_polygon_models);
  if (r->static_drawables) g_ptr_array_unref (r->static_drawables);
  if (r->body_models) g_ptr_array_unref (r->body_models);
  if (r->overlay_models) g_ptr_array_unref (r->overlay_models);
  if (r->map_labels) g_array_free (r->map_labels, TRUE);
  if (r->billboards) g_array_free (r->billboards, TRUE);
  g_clear_object (&r->orb_tex);
  g_clear_object (&r->glow_tex);
  if (r->bg_tex_ok) UnloadTexture (r->bg_tex);
  if (r->bg_src_notify && r->bg_src_data) r->bg_src_notify (r->bg_src_data);
  g_free (r->bg_src_rgba);
  g_free (r->bg_path);
  g_clear_object (&r->particle_pool);
  g_clear_object (&r->burst_emitter);
  if (r->particle_emitters) g_array_free (r->particle_emitters, TRUE);
  if (r->particle_tex_ok) UnloadTexture (r->particle_tex);
  g_clear_object (&r->camera);
  if (r->drawables) g_ptr_array_unref (r->drawables);
  if (r->nodes) g_array_free (r->nodes, TRUE);
  g_clear_object (&r->renderer);
  g_free (r);
}

void
cmacs_libregnum_render_ctx_resize (CmacsLibregnumRenderCtx *r, int w, int h)
{
  RenderTexture2D nfbo;
  if (!r) return;
  if (w == r->width && h == r->height) return;
  /* Allocate the new target BEFORE discarding the old one.  If allocation
   * fails -- e.g. this is reached from a Lisp timer before the view's GL
   * context is current -- keep the current (valid) FBO and do NOT record the
   * new size, so a later resize (the window-size idle hook, once the context
   * is ready) retries.  The previous code unconditionally stored w/h even on
   * failure, so the retry early-returned and the view stayed blank forever. */
  nfbo = LoadRenderTexture (w, h);
  if (nfbo.id == 0)
    return;
  if (r->fbo_valid)
    UnloadRenderTexture (r->fbo);
  /* The cached wrapper points at the old fbo.texture; drop it so the lrg
     overlay re-wraps the new render target on its next paint.  */
  g_clear_object (&r->fbo_grl_texture);
  r->fbo = nfbo;
  r->fbo_valid = TRUE;
  r->width = w;
  r->height = h;

  /* A hosted game has no window of its own, so lrg_game_template_get_window_size
   * returns the template's cached size (defaulting to 1280x720) -- it does not
   * track our FBO.  Push the new size in so the game (e.g. a screensaver's
   * u_resolution + fullscreen quad) re-renders at the right resolution on
   * resize; this also fires its `window-size-changed' signal. */
  if (r->game_mode && r->game != NULL)
    lrg_game_template_set_window_size (r->game, w, h);
}

/* ══════════════════════════════════════════════════════════════════════
 * 2D image-display mode
 *
 * A content-agnostic live viewport for the imgedit / vidstudio editors:
 * displays a composited RGBA image as a pan/zoomed textured quad over a
 * transparency checkerboard, with a 2D overlay (pixel grid, selection
 * marquee, brush cursor).  Mirrors the game_mode early-return branch in
 * render_to_bgra.  GPU work (texture upload + draw) runs ONLY at frame top
 * inside BeginTextureMode where the shared GL context is current; the
 * image_* setters below merely stash a source + flip image_upload_pending,
 * so they are safe to call from any Lisp DEFUN (deferred-upload discipline).
 * ══════════════════════════════════════════════════════════════════════ */

/* Consume a pending upload into image_tex (frame-top, GL context current).
 * Unifies the three sources (bound document / owned GrlImage / raw RGBA) by
 * resolving each to a GrlImage, then create-or-update the texture. */
static void
ctx_image_apply_upload (CmacsLibregnumRenderCtx *r)
{
  GrlImage *img = NULL;      /* borrowed for image_doc; owned otherwise */
  gboolean  own = FALSE;

  if (!r->image_upload_pending)
    return;
  r->image_upload_pending = FALSE;

  if (r->image_doc)
    img = lrg_image_document_flatten ((LrgImageDocument *) r->image_doc);
  else if (r->image_pending)
    img = r->image_pending;                 /* owned; cleared below */
  else if (r->image_rgba)
    {
      img = grl_image_new_from_pixels (r->image_rgba_w, r->image_rgba_h,
                                       GRL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
                                       r->image_rgba);
      own = TRUE;
    }

  if (img)
    {
      int w = grl_image_get_width (img);
      int h = grl_image_get_height (img);

      /* Create-vs-update decision keys on the TEXTURE's actual size, not the
       * logical doc size (which the bind setters preset before this runs so
       * fit/view_to_doc work before the first frame). */
      if (!r->image_tex || w != r->image_tex_w || h != r->image_tex_h)
        {
          g_clear_object (&r->image_tex);
          r->image_tex = grl_texture_new_from_image (img);
          if (r->image_tex)
            grl_texture_set_filter (r->image_tex, GRL_TEXTURE_FILTER_POINT);
          r->image_tex_w = w;
          r->image_tex_h = h;
        }
      else
        {
          grl_texture_update (r->image_tex, img);
        }
      r->image_doc_w = w;
      r->image_doc_h = h;
    }

  /* Ownership: image_doc's flatten is transfer-none (leave it); image_pending
   * and the raw-built image are owned (release). */
  if (own && img)
    g_object_unref (img);
  else if (r->image_pending)
    g_clear_object (&r->image_pending);
  g_clear_pointer (&r->image_rgba, g_free);
}

/* Transparency checkerboard under the doc's on-screen rect (8px screen tiles). */
static void
ctx_image_draw_checker (CmacsLibregnumRenderCtx *r)
{
  int x0, y0, w, h, xx, yy, t = 8;
  g_autoptr (GrlColor) c1 = grl_color_new (120, 120, 128, 255);
  g_autoptr (GrlColor) c2 = grl_color_new (90, 90, 98, 255);

  if (r->image_doc_w <= 0 || r->image_doc_h <= 0)
    return;
  x0 = (int) r->image_pan_x;
  y0 = (int) r->image_pan_y;
  w  = (int) (r->image_doc_w * r->image_scale);
  h  = (int) (r->image_doc_h * r->image_scale);
  for (yy = 0; yy < h; yy += t)
    for (xx = 0; xx < w; xx += t)
      {
        GrlColor *c = (((xx / t) + (yy / t)) & 1) ? c1 : c2;
        grl_draw_rectangle (x0 + xx, y0 + yy, MIN (t, w - xx), MIN (t, h - yy),
                            c);
      }
}

/* 2D overlay: pixel grid (high zoom), selection marquee, brush cursor. */
static void
ctx_image_draw_overlay (CmacsLibregnumRenderCtx *r)
{
  double px = r->image_pan_x, py = r->image_pan_y, s = r->image_scale;

  if (r->image_grid && s >= 4.0 && r->image_doc_w > 0)
    {
      g_autoptr (GrlColor) g = grl_color_new (255, 255, 255, 40);
      int i, y1 = (int) py, y2 = (int) (py + r->image_doc_h * s);
      int x1 = (int) px, x2 = (int) (px + r->image_doc_w * s);
      for (i = 0; i <= r->image_doc_w; i++)
        { int sx = (int) (px + i * s); grl_draw_line (sx, y1, sx, y2, g); }
      for (i = 0; i <= r->image_doc_h; i++)
        { int sy = (int) (py + i * s); grl_draw_line (x1, sy, x2, sy, g); }
    }
  if (r->image_marquee_on)
    {
      g_autoptr (GrlColor) m = grl_color_new (255, 255, 255, 220);
      grl_draw_rectangle_lines ((int) (px + r->image_mx * s),
                                (int) (py + r->image_my * s),
                                (int) (r->image_mw * s),
                                (int) (r->image_mh * s), m);
    }
  if (r->image_cursor_x >= 0)
    {
      g_autoptr (GrlColor) c = grl_color_new (255, 255, 255, 180);
      grl_draw_circle_lines ((int) (px + r->image_cursor_x * s),
                             (int) (py + r->image_cursor_y * s),
                             (gfloat) MAX (1.0, r->image_cursor_r * s), c);
    }

  /* Timeline strip along the bottom (vidstudio): one row per track, clip
   * blocks scaled to the FBO width, plus a playhead line. */
  if (r->image_clips != NULL && r->image_total_frames > 0)
    {
      int strip_h = MAX (24, r->height / 6);
      int y0 = r->height - strip_h;
      int ntr = MAX (1, r->image_ntracks);
      int rowh = strip_h / ntr;
      guint i;
      g_autoptr (GrlColor) bg = grl_color_new (20, 20, 24, 220);
      g_autoptr (GrlColor) ph = grl_color_new (255, 90, 90, 255);
      grl_draw_rectangle (0, y0, r->width, strip_h, bg);
      for (i = 0; i < r->image_clips->len; i++)
        {
          CmacsTimelineClip *cl =
            &g_array_index (r->image_clips, CmacsTimelineClip, i);
          g_autoptr (GrlColor) col = grl_color_new (cl->r, cl->g, cl->b, 235);
          g_autoptr (GrlColor) edge = grl_color_new (0, 0, 0, 255);
          int bx = cl->start * r->width / r->image_total_frames;
          int bw = MAX (2, cl->dur * r->width / r->image_total_frames);
          int by = y0 + cl->track * rowh;
          grl_draw_rectangle (bx, by + 1, bw, rowh - 2, col);
          grl_draw_rectangle_lines (bx, by + 1, bw, rowh - 2, edge);
          /* Clip id label on the block (drop-shadow for contrast), drawn
             only when it fits inside the block width.  Uses the configured
             label font (the Emacs UI font) when set, else the default. */
          {
            char idbuf[16];
            int fs = MAX (11, MIN (20, rowh - 6));
            int tw, tx, ty;
            g_snprintf (idbuf, sizeof idbuf, "#%d", cl->id);
            if (r->label_font != NULL)
              {
                g_autoptr (GrlVector2) m =
                  grl_font_measure_text (r->label_font, idbuf,
                                         (gfloat) fs, 1.0f);
                tw = m ? (int) grl_vector2_get_x (m) : fs * 2;
              }
            else
              tw = grl_measure_text (idbuf, fs);
            tx = bx + 4;
            ty = by + (rowh - fs) / 2;
            if (bw > tw + 6)
              {
                g_autoptr (GrlColor) sh = grl_color_new (0, 0, 0, 210);
                g_autoptr (GrlColor) fg = grl_color_new (255, 255, 255, 255);
                if (r->label_font != NULL)
                  {
                    g_autoptr (GrlVector2) ps = grl_vector2_new (tx + 1, ty + 1);
                    g_autoptr (GrlVector2) pf = grl_vector2_new (tx, ty);
                    grl_draw_text_ex (r->label_font, idbuf, ps,
                                      (gfloat) fs, 1.0f, sh);
                    grl_draw_text_ex (r->label_font, idbuf, pf,
                                      (gfloat) fs, 1.0f, fg);
                  }
                else
                  {
                    grl_draw_text (idbuf, tx + 1, ty + 1, fs, sh);
                    grl_draw_text (idbuf, tx, ty, fs, fg);
                  }
              }
          }
        }
      {
        int phx = r->image_playhead * r->width / r->image_total_frames;
        grl_draw_rectangle (phx, y0, 2, strip_h, ph);
      }
    }
}

void
cmacs_libregnum_render_ctx_image_timeline_clear (CmacsLibregnumRenderCtx *r)
{
  if (!r) return;
  if (r->image_clips)
    g_array_set_size (r->image_clips, 0);
}

void
cmacs_libregnum_render_ctx_image_timeline_add_clip (CmacsLibregnumRenderCtx *r,
                                                    int id, int track, int start,
                                                    int dur, guint8 cr,
                                                    guint8 cg, guint8 cb)
{
  CmacsTimelineClip c;
  if (!r) return;
  if (r->image_clips == NULL)
    r->image_clips = g_array_new (FALSE, FALSE, sizeof (CmacsTimelineClip));
  c.id = id; c.track = track; c.start = start; c.dur = dur;
  c.r = cr; c.g = cg; c.b = cb;
  g_array_append_val (r->image_clips, c);
}

/* Hit-test a view-space point against the timeline strip.  Returns TRUE when
   (VX,VY) is inside the strip (VW×VH view size).  Sets *FRAME to the frame
   under the cursor, *CLIP_ID to the clip there (-1 if none), and *EDGE to
   which edge of that clip the cursor is near: 0 = body, 1 = right (out/trim
   end), 2 = left (in/trim start). */
gboolean
cmacs_libregnum_render_ctx_image_timeline_hit (CmacsLibregnumRenderCtx *r,
                                               double vx, double vy,
                                               int vw, int vh, int *frame,
                                               int *clip_id, int *edge)
{
  int strip_h, y0, ntr, rowh, f, row;
  guint i;
  if (frame) *frame = 0;
  if (clip_id) *clip_id = -1;
  if (edge) *edge = 0;
  if (!r || r->image_clips == NULL || r->image_total_frames <= 0 || vw <= 0)
    return FALSE;
  strip_h = MAX (24, vh / 6);
  y0 = vh - strip_h;
  if (vy < y0)
    return FALSE;                        /* above the strip */
  f = (int) (vx * r->image_total_frames / vw);
  f = CLAMP (f, 0, r->image_total_frames - 1);
  if (frame) *frame = f;
  ntr = MAX (1, r->image_ntracks);
  rowh = strip_h / ntr;
  row = rowh > 0 ? (int) ((vy - y0) / rowh) : 0;
  for (i = 0; i < r->image_clips->len; i++)
    {
      CmacsTimelineClip *cl =
        &g_array_index (r->image_clips, CmacsTimelineClip, i);
      if (cl->track != row)
        continue;
      if (f >= cl->start && f < cl->start + cl->dur)
        {
          if (clip_id) *clip_id = cl->id;
          if (edge)
            {
              int right_px =
                (cl->start + cl->dur) * vw / r->image_total_frames;
              int left_px = cl->start * vw / r->image_total_frames;
              if (ABS (right_px - (int) vx) <= 8)
                *edge = 1;               /* right: out-point / trim end */
              else if (ABS (left_px - (int) vx) <= 8)
                *edge = 2;               /* left: in-point / trim start */
            }
          break;
        }
    }
  return TRUE;                            /* inside the strip region */
}

void
cmacs_libregnum_render_ctx_image_timeline_set (CmacsLibregnumRenderCtx *r,
                                               int playhead, int total,
                                               int ntracks)
{
  if (!r) return;
  r->image_playhead = playhead;
  r->image_total_frames = total;
  r->image_ntracks = ntracks;
}

/* Build the codepoint set baked into a label font atlas.
 *
 * The loader's default set is the 95 printable ASCII characters, which
 * is not enough for text a user wrote: an em dash, a curly quote or an
 * accented name all come out as the missing-glyph box.  Org note titles
 * are full of exactly those.  So bake ASCII plus Latin-1 Supplement
 * plus General Punctuation -- around 300 glyphs, a trivial atlas. */
static gint *
label_font_codepoints (gint *n_out)
{
  gint *cp;
  gint n = 0, i;

  /* 0x20-0x7E, 0xA0-0xFF, 0x2010-0x205E, plus a few strays. */
  cp = g_new0 (gint, 95 + 96 + 79 + 8);

  for (i = 0x20; i <= 0x7E; i++)   cp[n++] = i;
  for (i = 0xA0; i <= 0xFF; i++)   cp[n++] = i;
  for (i = 0x2010; i <= 0x205E; i++) cp[n++] = i;
  cp[n++] = 0x20AC;    /* euro sign */
  cp[n++] = 0x2192;    /* rightwards arrow, used in breadcrumbs */
  cp[n++] = 0x2190;    /* leftwards arrow */
  cp[n++] = 0x2026;    /* horizontal ellipsis (also inside the range) */

  if (n_out) *n_out = n;
  return cp;
}

/* Set the font used for in-scene node labels and the timeline-strip
   clip-id labels (e.g. the Emacs UI font, so the text matches the
   editor).  PATH is a TTF/OTF file; NULL/empty or an unloadable file
   falls back to the built-in bitmap font. */
void
cmacs_libregnum_render_ctx_set_label_font (CmacsLibregnumRenderCtx *r,
                                           const char *path, int base_px)
{
  if (!r) return;
  g_clear_object (&r->label_font);
  if (path != NULL && path[0] != '\0')
    {
      /* Bake large and draw small: downsampling a 32px atlas through the
       * bilinear filter is what makes the text look right, and it makes
       * the draw size a free runtime knob with no font reload. */
      gint ncp = 0;
      g_autofree gint *cp = label_font_codepoints (&ncp);
      GrlFont *f = grl_font_new_from_file_ex (path,
                                              (base_px > 0) ? base_px : 32,
                                              cp, ncp);
      if (f != NULL && grl_font_is_valid (f))
        {
          grl_font_set_filter (f, GRL_TEXTURE_FILTER_BILINEAR);
          r->label_font = f;
        }
      else
        g_clear_object (&f);
    }
}

/* Back-compat alias: vidstudio's timeline overlay named this first, and
   the font is now shared with the in-scene node labels. */
void
cmacs_libregnum_render_ctx_image_set_label_font (CmacsLibregnumRenderCtx *r,
                                                 const char *path)
{
  cmacs_libregnum_render_ctx_set_label_font (r, path, 0);
}

void
cmacs_libregnum_render_ctx_set_inscene_labels (CmacsLibregnumRenderCtx *r,
                                               gboolean on)
{
  if (!r) return;
  r->inscene_labels = on;
}

/* Suppress orbiting (pan and zoom keep working).  For a scene whose
   content is planar and viewed head-on, tumbling the camera only
   reveals that everything is coplanar. */
/* Label decoration: a translucent plate behind the text, and
   screen-space rings on the selected / hovered / matched nodes.  Both
   off by default so existing scenes are untouched. */
void
cmacs_libregnum_render_ctx_set_label_decor (CmacsLibregnumRenderCtx *r,
                                            gboolean backdrop,
                                            gboolean rings)
{
  if (!r) return;
  r->label_backdrop = backdrop;
  r->emphasis_rings = rings;
}

/* How the selected node is marked in the 3D pass.  The legacy wireframe
   box suits the file-tree and editor scenes, whose nodes ARE boxes; a
   scene made of spheres wants a halo instead, and one drawing its own
   screen-space rings wants neither. */
void
cmacs_libregnum_render_ctx_set_selection_style (CmacsLibregnumRenderCtx *r,
                                                int style)
{
  if (!r) return;
  r->selection_style = style;
}

void
cmacs_libregnum_render_ctx_set_orbit_locked (CmacsLibregnumRenderCtx *r,
                                             gboolean locked)
{
  if (!r) return;
  r->orbit_locked = locked;
}

gboolean
cmacs_libregnum_render_ctx_orbit_locked_p (CmacsLibregnumRenderCtx *r)
{
  return r ? r->orbit_locked : FALSE;
}

/* Choose what a right-drag does.  The default CAD profile orbits with
   either button and pans with the middle one, which suits a modelling
   viewport; a map-like scene wants right-drag to pan, because that is
   what every map does and because a middle button is not always
   there. */
void
cmacs_libregnum_render_ctx_set_right_drag_pans (CmacsLibregnumRenderCtx *r,
                                                gboolean pans)
{
  if (!r) return;
  r->right_drag_pans = pans;
}

gboolean
cmacs_libregnum_render_ctx_right_drag_pans_p (CmacsLibregnumRenderCtx *r)
{
  return r ? r->right_drag_pans : FALSE;
}

/* Wheel direction.  GDK reports a positive delta for scrolling DOWN, and
   the zoom kernel moves closer for a positive amount, so the inherited
   behaviour is that scrolling down moves you closer -- the opposite of
   what maps, browsers and 3-D viewers all do.  Contexts opt into the
   conventional direction rather than it being flipped underneath the
   scenes that already shipped with the old one. */
void
cmacs_libregnum_render_ctx_set_wheel_up_zooms_in (CmacsLibregnumRenderCtx *r,
                                                  gboolean up_zooms_in)
{
  if (!r) return;
  r->wheel_up_zooms_in = up_zooms_in;
}

gboolean
cmacs_libregnum_render_ctx_wheel_up_zooms_in_p (CmacsLibregnumRenderCtx *r)
{
  return r ? r->wheel_up_zooms_in : FALSE;
}

/* Current framebuffer size.  Scene builders need the aspect ratio to
   frame content correctly. */
void
cmacs_libregnum_render_ctx_get_size (CmacsLibregnumRenderCtx *r,
                                     int *w, int *h)
{
  if (w) *w = r ? r->width : 0;
  if (h) *h = r ? r->height : 0;
}

gboolean
cmacs_libregnum_render_ctx_inscene_labels_p (CmacsLibregnumRenderCtx *r)
{
  return r ? r->inscene_labels : FALSE;
}

void
cmacs_libregnum_render_ctx_set_label_style (CmacsLibregnumRenderCtx *r,
                                            int px, gboolean shadow,
                                            gboolean declutter, int max_labels)
{
  if (!r) return;
  r->label_px        = (px > 0) ? px : 0;
  r->label_shadow    = shadow;
  r->label_declutter = declutter;
  r->label_max       = (max_labels > 0) ? max_labels : 0;
}

/* Should node ID carry a label this frame?  Single source of truth for
   the per-node label policy, shared by the in-scene pass and the legacy
   cairo overlay so the two can never disagree. */
gboolean
cmacs_libregnum_render_ctx_label_visible_p (CmacsLibregnumRenderCtx *r,
                                            guint id)
{
  CmacsNode *n;

  if (!r || !r->nodes || id >= r->nodes->len) return FALSE;
  n = &g_array_index (r->nodes, CmacsNode, id);

  /* A search hit, a pin or a selection neighbour is labelled whatever
     its own policy says: the point of highlighting something is to be
     able to read its name without hunting for it. */
  if (n->flags & (CMACS_LIBREGNUM_NODE_MATCH
                  | CMACS_LIBREGNUM_NODE_PINNED
                  | CMACS_LIBREGNUM_NODE_NEIGHBOUR))
    return TRUE;

  switch (n->label_mode)
    {
    case CMACS_LIBREGNUM_LABEL_NEVER:
      return FALSE;
    case CMACS_LIBREGNUM_LABEL_ALWAYS:
      return TRUE;
    case CMACS_LIBREGNUM_LABEL_SELECTED:
      return r->selected == (gint) id;
    case CMACS_LIBREGNUM_LABEL_HOVER:
      return r->selected == (gint) id || r->hovered == (gint) id;
    default:
      /* Legacy: directories, plus whatever is selected. */
      return n->is_dir || r->selected == (gint) id;
    }
}

/* Full image-mode frame; called from the render_to_bgra branch. */
static gboolean
ctx_render_image (CmacsLibregnumRenderCtx *r, unsigned char *dst)
{
  ctx_image_apply_upload (r);
  BeginTextureMode (r->fbo);
  ClearBackground ((Color){ 40, 40, 46, 255 });
  if (r->image_checker)
    ctx_image_draw_checker (r);
  if (r->image_tex && r->image_doc_w > 0)
    {
      g_autoptr (GrlRectangle) src =
        grl_rectangle_new (0, 0, r->image_doc_w, r->image_doc_h);
      g_autoptr (GrlRectangle) dstr =
        grl_rectangle_new ((gfloat) r->image_pan_x, (gfloat) r->image_pan_y,
                           (gfloat) (r->image_doc_w * r->image_scale),
                           (gfloat) (r->image_doc_h * r->image_scale));
      g_autoptr (GrlVector2) org = grl_vector2_new (0.0f, 0.0f);
      g_autoptr (GrlColor) white = grl_color_new (255, 255, 255, 255);
      grl_draw_texture_pro (r->image_tex, src, dstr, org, 0.0f, white);
    }
  ctx_image_draw_overlay (r);
  /* Flush the rlgl 2D batch to the FBO BEFORE reading it back: DrawRectangle/
   * DrawTexturePro queue into the render batch and are only submitted to GL on
   * a batch flush (normally EndTextureMode).  Without this the glReadPixels
   * below would capture the just-cleared FBO -- an all-background frame. */
  rlDrawRenderBatchActive ();
  if (dst)
    glReadPixels (0, 0, r->width, r->height, GL_BGRA, GL_UNSIGNED_BYTE, dst);
  EndTextureMode ();
  return TRUE;
}

/* Full chart-mode frame; called from the render_to_bgra branch.
 *
 * Mirrors ctx_render_image: all GPU work stays inside the
 * BeginTextureMode/EndTextureMode bracket, the rlgl batch is flushed before
 * the readback, and DST may be NULL.
 *
 * The DST==NULL case is the `emacs --lrg' path: render_into_fbo asks for the
 * frame to land in the FBO only, and the lrg present blits fbo.texture
 * directly.  Under pgtk, DST is the BGRA buffer the cairo overlay blits.
 * Both backends therefore go through this one function -- keep it that way,
 * and keep the batch flush unconditional: with DST==NULL the missing flush
 * would be invisible (EndTextureMode submits the batch later), so a chart
 * that renders fine under --lrg would come back blank under pgtk. */
static gboolean
ctx_render_chart (CmacsLibregnumRenderCtx *r, unsigned char *dst)
{
  BeginTextureMode (r->fbo);
  if (r->chart_bg_set)
    ClearBackground ((Color){ r->chart_bg_r, r->chart_bg_g,
                              r->chart_bg_b, r->chart_bg_a });
  else
    ClearBackground ((Color){ 24, 24, 28, 255 });

  if (r->chart != NULL)
    {
      /* Size the widget to the FBO every frame: the view is resized by the
       * window, not by the chart, so the widget must follow it. */
      lrg_widget_set_position (LRG_WIDGET (r->chart), 0.0f, 0.0f);
      lrg_widget_set_size (LRG_WIDGET (r->chart),
                           (gfloat) r->width, (gfloat) r->height);
      lrg_widget_draw (LRG_WIDGET (r->chart));
    }

  /* Charts draw through the immediate-mode grl_draw_* batch; submit it to
   * GL before reading the FBO back (see the comment above). */
  rlDrawRenderBatchActive ();
  if (dst)
    glReadPixels (0, 0, r->width, r->height, GL_BGRA, GL_UNSIGNED_BYTE, dst);
  EndTextureMode ();
  return TRUE;
}

void
cmacs_libregnum_render_ctx_chart_enter (CmacsLibregnumRenderCtx *r,
                                        gboolean on)
{
  if (!r) return;
  r->chart_mode = on;
  if (!on)
    {
      g_clear_object ((GObject **) &r->chart);
      r->chart_bg_set = FALSE;
    }
}

gboolean
cmacs_libregnum_render_ctx_is_chart (CmacsLibregnumRenderCtx *r)
{
  return r != NULL && r->chart_mode;
}

void
cmacs_libregnum_render_ctx_chart_set_widget (CmacsLibregnumRenderCtx *r,
                                             void *lrg_chart)
{
  if (!r) return;
  /* Ref the new widget before unreffing the old one: they may be the same
   * object, and dropping the last ref first would free it. */
  if (lrg_chart)
    g_object_ref (G_OBJECT (lrg_chart));
  g_clear_object ((GObject **) &r->chart);
  r->chart = lrg_chart;
}

void *
cmacs_libregnum_render_ctx_chart_get_widget (CmacsLibregnumRenderCtx *r)
{
  return r ? r->chart : NULL;
}

void
cmacs_libregnum_render_ctx_chart_set_background (CmacsLibregnumRenderCtx *r,
                                                 guint8 cr, guint8 cg,
                                                 guint8 cb, guint8 ca)
{
  if (!r) return;
  r->chart_bg_set = TRUE;
  r->chart_bg_r = cr;
  r->chart_bg_g = cg;
  r->chart_bg_b = cb;
  r->chart_bg_a = ca;
}

void
cmacs_libregnum_render_ctx_image_enter (CmacsLibregnumRenderCtx *r,
                                        gboolean on)
{
  if (!r) return;
  r->image_mode = on;
  if (on && r->image_scale <= 0.0)
    {
      r->image_scale = 1.0;
      r->image_pan_x = r->image_pan_y = 0.0;
      r->image_checker = TRUE;
      r->image_cursor_x = r->image_cursor_y = -1.0;
      r->image_cursor_r = 0.0;
    }
}

gboolean
cmacs_libregnum_render_ctx_is_image (CmacsLibregnumRenderCtx *r)
{ return r && r->image_mode; }

void
cmacs_libregnum_render_ctx_image_set_document (CmacsLibregnumRenderCtx *r,
                                               void *lrg_doc)
{
  if (!r) return;
  r->image_doc = lrg_doc;                 /* borrowed */
  if (lrg_doc)
    {
      r->image_doc_w = lrg_image_document_get_width ((LrgImageDocument *) lrg_doc);
      r->image_doc_h = lrg_image_document_get_height ((LrgImageDocument *) lrg_doc);
    }
  g_clear_object (&r->image_pending);
  g_clear_pointer (&r->image_rgba, g_free);
  r->image_upload_pending = TRUE;
}

void
cmacs_libregnum_render_ctx_image_set_grl_image (CmacsLibregnumRenderCtx *r,
                                                void *grl_image)
{
  if (!r) return;
  r->image_doc = NULL;
  g_clear_object (&r->image_pending);
  r->image_pending = grl_image;           /* transfer full */
  if (grl_image)
    {
      r->image_doc_w = grl_image_get_width ((GrlImage *) grl_image);
      r->image_doc_h = grl_image_get_height ((GrlImage *) grl_image);
    }
  g_clear_pointer (&r->image_rgba, g_free);
  r->image_upload_pending = TRUE;
}

void
cmacs_libregnum_render_ctx_image_upload_rgba (CmacsLibregnumRenderCtx *r,
                                              int w, int h,
                                              const guint8 *rgba, gsize n)
{
  if (!r || w <= 0 || h <= 0 || !rgba || n < (gsize) w * h * 4)
    return;
  r->image_doc = NULL;
  g_clear_object (&r->image_pending);
  g_clear_pointer (&r->image_rgba, g_free);
  r->image_rgba = g_memdup2 (rgba, (gsize) w * h * 4);
  r->image_rgba_w = w;
  r->image_rgba_h = h;
  r->image_doc_w = w;
  r->image_doc_h = h;
  r->image_upload_pending = TRUE;
}

void
cmacs_libregnum_render_ctx_image_refresh (CmacsLibregnumRenderCtx *r)
{ if (r) r->image_upload_pending = TRUE; }

void
cmacs_libregnum_render_ctx_image_refresh_rect (CmacsLibregnumRenderCtx *r,
                                               int x, int y, int w, int h)
{
  /* v1: a rect refresh is a full re-upload (still cheap for a bound document,
   * which re-flattens anyway).  A true dirty-rect grl_texture_update_rec path
   * is a later optimisation for very large canvases. */
  (void) x; (void) y; (void) w; (void) h;
  if (r) r->image_upload_pending = TRUE;
}

void
cmacs_libregnum_render_ctx_image_set_view (CmacsLibregnumRenderCtx *r,
                                           double scale, double pan_x,
                                           double pan_y)
{
  if (!r) return;
  r->image_scale = (scale > 0.01) ? scale : 0.01;
  r->image_pan_x = pan_x;
  r->image_pan_y = pan_y;
}

void
cmacs_libregnum_render_ctx_image_get_view (CmacsLibregnumRenderCtx *r,
                                           double *scale, double *pan_x,
                                           double *pan_y)
{
  if (!r) return;
  if (scale) *scale = r->image_scale;
  if (pan_x) *pan_x = r->image_pan_x;
  if (pan_y) *pan_y = r->image_pan_y;
}

/* Zoom about a view pixel, keeping the doc point under it fixed. */
void
cmacs_libregnum_render_ctx_image_zoom_at (CmacsLibregnumRenderCtx *r,
                                          double vx, double vy, double factor)
{
  double s0, s1;
  if (!r || factor <= 0.0) return;
  s0 = r->image_scale;
  s1 = s0 * factor;
  if (s1 < 0.02) s1 = 0.02;
  if (s1 > 64.0) s1 = 64.0;
  /* doc point under the cursor before = (vx - pan)/s0; keep it under vx. */
  r->image_pan_x = vx - (vx - r->image_pan_x) * (s1 / s0);
  r->image_pan_y = vy - (vy - r->image_pan_y) * (s1 / s0);
  r->image_scale = s1;
}

/* Fit the whole doc into a VW×VH viewport, centred. */
void
cmacs_libregnum_render_ctx_image_fit (CmacsLibregnumRenderCtx *r,
                                      int vw, int vh)
{
  double sx, sy, s;
  if (!r || r->image_doc_w <= 0 || r->image_doc_h <= 0 || vw <= 0 || vh <= 0)
    return;
  sx = (double) vw / r->image_doc_w;
  sy = (double) vh / r->image_doc_h;
  s = (sx < sy) ? sx : sy;
  if (s < 0.02) s = 0.02;
  r->image_scale = s;
  r->image_pan_x = (vw - r->image_doc_w * s) * 0.5;
  r->image_pan_y = (vh - r->image_doc_h * s) * 0.5;
}

/* View (FBO-local) pixel → document pixel, honouring pan/zoom.  Returns FALSE
 * when the point is outside the document. */
gboolean
cmacs_libregnum_render_ctx_image_view_to_doc (CmacsLibregnumRenderCtx *r,
                                              double vx, double vy,
                                              int *dx, int *dy)
{
  int x, y;
  if (!r || r->image_scale <= 0.0) return FALSE;
  x = (int) floor ((vx - r->image_pan_x) / r->image_scale);
  y = (int) floor ((vy - r->image_pan_y) / r->image_scale);
  if (dx) *dx = x;
  if (dy) *dy = y;
  return (x >= 0 && x < r->image_doc_w && y >= 0 && y < r->image_doc_h);
}

void
cmacs_libregnum_render_ctx_image_set_checker (CmacsLibregnumRenderCtx *r,
                                              gboolean on)
{ if (r) r->image_checker = on; }

void
cmacs_libregnum_render_ctx_image_set_grid (CmacsLibregnumRenderCtx *r,
                                           gboolean on)
{ if (r) r->image_grid = on; }

void
cmacs_libregnum_render_ctx_image_set_cursor (CmacsLibregnumRenderCtx *r,
                                             double dx, double dy,
                                             double radius)
{
  if (!r) return;
  r->image_cursor_x = dx;
  r->image_cursor_y = dy;
  r->image_cursor_r = radius;
}

void
cmacs_libregnum_render_ctx_image_set_marquee (CmacsLibregnumRenderCtx *r,
                                              gboolean on, int x, int y,
                                              int w, int h)
{
  if (!r) return;
  r->image_marquee_on = on;
  r->image_mx = x; r->image_my = y; r->image_mw = w; r->image_mh = h;
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

void
cmacs_libregnum_render_ctx_set_focus_min (CmacsLibregnumRenderCtx *r,
                                          double dist)
{
  if (r) r->focus_min_dist = dist > 0.0 ? dist : 0.0;
}

static BodyModel *
ctx_find_body (CmacsLibregnumRenderCtx *r, const gchar *key)
{
  if (!r || !r->body_models || !key) return NULL;
  for (guint i = 0; i < r->body_models->len; i++)
    {
      BodyModel *b = g_ptr_array_index (r->body_models, i);
      if (g_strcmp0 (b->key, key) == 0) return b;
    }
  return NULL;
}

/* Update the position of body KEY; FALSE if it does not exist yet. */
gboolean
cmacs_libregnum_render_ctx_body_model_update (CmacsLibregnumRenderCtx *r,
                                              const gchar *key,
                                              double x, double y, double z)
{
  BodyModel *b = ctx_find_body (r, key);
  if (!b) return FALSE;
  b->x = x; b->y = y; b->z = z;
  return TRUE;
}

/* Register (or replace) body KEY with MODEL (a GrlModel*, ownership
 * transferred). */
void
cmacs_libregnum_render_ctx_body_model_add (CmacsLibregnumRenderCtx *r,
                                           const gchar *key, gpointer model,
                                           double x, double y, double z)
{
  if (!r || !key || !model) return;
  BodyModel *b = ctx_find_body (r, key);
  if (b)
    {
      g_clear_object (&b->model);
      b->model = model;
      b->x = x; b->y = y; b->z = z;
      return;
    }
  b = g_new0 (BodyModel, 1);
  b->key = g_strdup (key);
  b->model = model;
  b->x = x; b->y = y; b->z = z;
  g_ptr_array_add (r->body_models, b);
}

void
cmacs_libregnum_render_ctx_clear_body_models (CmacsLibregnumRenderCtx *r)
{
  if (r && r->body_models)
    g_ptr_array_set_size (r->body_models, 0);
}

/* ── Translucent overlay shells (gnuseye weather drapes) ────────────── */

static CmacsOverlayModel *
ctx_find_overlay (CmacsLibregnumRenderCtx *r, const gchar *key)
{
  if (!r || !r->overlay_models || !key) return NULL;
  for (guint i = 0; i < r->overlay_models->len; i++)
    {
      CmacsOverlayModel *o = g_ptr_array_index (r->overlay_models, i);
      if (g_strcmp0 (o->key, key) == 0) return o;
    }
  return NULL;
}

void
cmacs_libregnum_render_ctx_overlay_model_set (CmacsLibregnumRenderCtx *r,
                                              const gchar *key,
                                              gpointer model, double sort_key)
{
  if (!r || !key) return;
  CmacsOverlayModel *o = ctx_find_overlay (r, key);
  if (!model)
    {
      if (o) g_ptr_array_remove (r->overlay_models, o);
      return;
    }
  if (o)
    {
      g_clear_object (&o->model);
      o->model = model;
      o->sort_key = (gfloat) sort_key;
    }
  else
    {
      if (!r->overlay_models)
        r->overlay_models =
          g_ptr_array_new_with_free_func (overlay_model_free);
      o = g_new0 (CmacsOverlayModel, 1);
      o->key = g_strdup (key);
      o->model = model;
      o->alpha = 1.0f;
      o->enabled = TRUE;
      o->sort_key = (gfloat) sort_key;
      g_ptr_array_add (r->overlay_models, o);
    }
  /* Keep ascending by sort_key: higher shells draw later and composite
   * over the lower ones. */
  if (r->overlay_models->len > 1)
    {
      GPtrArray *a = r->overlay_models;
      for (guint i = 1; i < a->len; i++)
        for (guint j = i; j > 0; j--)
          {
            CmacsOverlayModel *p = g_ptr_array_index (a, j - 1);
            CmacsOverlayModel *q = g_ptr_array_index (a, j);
            if (p->sort_key <= q->sort_key) break;
            a->pdata[j - 1] = q;
            a->pdata[j] = p;
          }
    }
}

gpointer
cmacs_libregnum_render_ctx_overlay_model_get (CmacsLibregnumRenderCtx *r,
                                              const gchar *key)
{
  CmacsOverlayModel *o = ctx_find_overlay (r, key);
  return o ? o->model : NULL;
}

void
cmacs_libregnum_render_ctx_overlay_set_alpha (CmacsLibregnumRenderCtx *r,
                                              const gchar *key, double alpha)
{
  CmacsOverlayModel *o = ctx_find_overlay (r, key);
  if (!o) return;
  if (alpha < 0.0) alpha = 0.0;
  if (alpha > 1.0) alpha = 1.0;
  o->alpha = (gfloat) alpha;
}

void
cmacs_libregnum_render_ctx_overlay_set_enabled (CmacsLibregnumRenderCtx *r,
                                                const gchar *key,
                                                gboolean enabled)
{
  CmacsOverlayModel *o = ctx_find_overlay (r, key);
  if (o) o->enabled = enabled;
}

void
cmacs_libregnum_render_ctx_clear_overlay_models (CmacsLibregnumRenderCtx *r)
{
  if (r && r->overlay_models)
    g_ptr_array_set_size (r->overlay_models, 0);
}

/* TRUE if world point (X,Y,Z) is visible from the camera, i.e. the globe
 * does not block the line of sight.  The point is occluded only when the
 * SEGMENT from the camera to the point passes through the occluder sphere
 * before reaching it -- the correct test for points at any altitude.  (The
 * old dot(P,C) > R*R limb test was only right for surface points: it
 * wrongly culled far-side celestial bodies that float high above the globe
 * and are plainly visible beside the limb.) */
static gboolean
ctx_point_near_side (CmacsLibregnumRenderCtx *r, double x, double y, double z)
{
  if (!r || r->occluder_radius <= 0.0) return TRUE;
  double px, py, pz, tx, ty, tz, fov;
  cmacs_libregnum_render_ctx_get_camera_state (r, &px, &py, &pz,
                                               &tx, &ty, &tz, &fov);
  double r2 = r->occluder_radius * r->occluder_radius;
  double c2 = px * px + py * py + pz * pz;
  if (c2 <= r2) return TRUE;            /* camera inside the sphere: show */
  double dx = x - px, dy = y - py, dz = z - pz;
  double len2 = dx * dx + dy * dy + dz * dz;
  if (len2 < 1e-12) return TRUE;
  /* Closest approach of the segment C + t*(P-C), t in [0,1], to the
   * origin: t* = -(C . D) / |D|^2.  Outside (0,1) the sphere cannot sit
   * between the camera and the point. */
  double t = -(px * dx + py * dy + pz * dz) / len2;
  if (t <= 0.0 || t >= 1.0) return TRUE;
  double qx = px + t * dx, qy = py + t * dy, qz = pz + t * dz;
  return (qx * qx + qy * qy + qz * qz) > r2;
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

/* ── Filled polygon models (translucent draped fills) ────────────── */

void
cmacs_libregnum_render_ctx_add_polygon_model (CmacsLibregnumRenderCtx *r,
                                              void *model)
{
  if (!r || !model) return;
  g_ptr_array_add (r->polygon_models, model);          /* ownership transfers */
}

void
cmacs_libregnum_render_ctx_clear_polygon_models (CmacsLibregnumRenderCtx *r)
{
  if (r && r->polygon_models)
    g_ptr_array_set_size (r->polygon_models, 0);
}

void
cmacs_libregnum_render_ctx_add_static_polygon_model (CmacsLibregnumRenderCtx *r,
                                                     void *model)
{
  if (!r || !model) return;
  g_ptr_array_add (r->static_polygon_models, model);   /* ownership transfers */
}

void
cmacs_libregnum_render_ctx_clear_static_polygon_models
                                              (CmacsLibregnumRenderCtx *r)
{
  if (r && r->static_polygon_models)
    g_ptr_array_set_size (r->static_polygon_models, 0);
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

gint
cmacs_libregnum_render_ctx_add_billboard_full (CmacsLibregnumRenderCtx *r,
                                               float x, float y, float z,
                                               void *texture, float size,
                                               guint32 rgba)
{
  CmacsBillboard b = { 0 };

  if (!r || !r->billboards || !texture) return -1;
  b.x = x; b.y = y; b.z = z; b.size = size;
  b.rgba = rgba;
  b.tex = (GrlTexture *) texture;     /* ownership transfers */
  g_array_append_val (r->billboards, b);
  return (gint) r->billboards->len - 1;
}

void
cmacs_libregnum_render_ctx_move_billboard (CmacsLibregnumRenderCtx *r,
                                           gint idx,
                                           float x, float y, float z)
{
  CmacsBillboard *b;
  if (!r || !r->billboards || idx < 0 || (guint) idx >= r->billboards->len)
    return;
  b = &g_array_index (r->billboards, CmacsBillboard, idx);
  b->x = x; b->y = y; b->z = z;
}

void
cmacs_libregnum_render_ctx_set_billboard_color (CmacsLibregnumRenderCtx *r,
                                                gint idx, guint32 rgba)
{
  if (!r || !r->billboards || idx < 0 || (guint) idx >= r->billboards->len)
    return;
  g_array_index (r->billboards, CmacsBillboard, idx).rgba = rgba;
}

void
cmacs_libregnum_render_ctx_set_billboard_size (CmacsLibregnumRenderCtx *r,
                                               gint idx, float size)
{
  if (!r || !r->billboards || idx < 0 || (guint) idx >= r->billboards->len)
    return;
  g_array_index (r->billboards, CmacsBillboard, idx).size = size;
}

/* ── The lit-sphere impostor ─────────────────────────────────────── */

#define CMACS_ORB_PX 256

/* Shade one texel of a sphere seen head-on.
 *
 * U and V are in [-1,1] across the quad.  Outside the unit disc the
 * texel is transparent; inside, the surface normal of a unit sphere at
 * that point is (u, v, sqrt (1 - r^2)) -- the near hemisphere, which is
 * all a viewer ever sees.  From that: a Lambert term for the body, a
 * Blinn-Phong specular for the highlight, and a Fresnel-ish rim.
 *
 * The result is a GREY level, because the caller tints it: one texture
 * serves every node colour.  That also decides the shape of the curve --
 * the tint is multiplied in, so the brightest a texel can be is the
 * node's own colour, and the useful range is therefore ambient..1. */
static void
orb_shade (double u, double v, double *out_lum, double *out_alpha)
{
  /* Light: upper-left and toward the viewer.  View is +Z by
     construction -- the quad always faces the camera, which is the
     whole reason this works from any angle. */
  static const double lx = -0.42, ly = 0.50, lz = 0.76;
  double r2 = u * u + v * v;
  double nz, ndl, spec, rim, lum;
  double hx, hy, hz, hlen, ndh;

  if (r2 >= 1.0)
    {
      *out_lum = 0.0;
      *out_alpha = 0.0;
      return;
    }

  nz = sqrt (1.0 - r2);

  ndl = u * lx + v * ly + nz * lz;
  if (ndl < 0.0) ndl = 0.0;

  /* Half-vector between light and view (0,0,1). */
  hx = lx; hy = ly; hz = lz + 1.0;
  hlen = sqrt (hx * hx + hy * hy + hz * hz);
  hx /= hlen; hy /= hlen; hz /= hlen;
  ndh = u * hx + v * hy + nz * hz;
  if (ndh < 0.0) ndh = 0.0;
  spec = pow (ndh, 42.0);

  /* Rim: bright where the surface turns away from the viewer.  This is
     what keeps a small node's silhouette readable against a dark
     background -- without it the unlit limb fades into the sky and the
     node looks like a crescent. */
  rim = pow (1.0 - nz, 3.0) * 0.45;

  /* Ambient is high on purpose.  The node's colour IS its PARA
     category, so a realistically dark terminator would make half of
     every node unidentifiable. */
  lum = 0.34 + 0.62 * ndl + 0.55 * spec + rim;
  if (lum > 1.0) lum = 1.0;

  /* Antialias the silhouette over roughly one texel of the 256 grid;
     a hard cut aliases badly once the orb is a few pixels across. */
  {
    double r = sqrt (r2);
    double edge = (1.0 - r) / (1.6 / (double) CMACS_ORB_PX * 2.0);
    *out_alpha = CLAMP (edge, 0.0, 1.0);
  }
  *out_lum = lum;
}

void *
cmacs_libregnum_render_ctx_orb_texture (CmacsLibregnumRenderCtx *r)
{
  const int N = CMACS_ORB_PX;
  Color *px;
  Image img = { 0 };
  Texture2D tex;
  int x, y;

  if (!r) return NULL;
  if (r->orb_tex) return r->orb_tex;

  px = g_new0 (Color, (gsize) N * N);
  for (y = 0; y < N; y++)
    for (x = 0; x < N; x++)
      {
        double u = (2.0 * ((double) x + 0.5) / N) - 1.0;
        double v = 1.0 - (2.0 * ((double) y + 0.5) / N);
        double lum, a;
        unsigned char c;

        orb_shade (u, v, &lum, &a);
        c = (unsigned char) CLAMP (lum * 255.0, 0.0, 255.0);
        px[y * N + x] = (Color){ c, c, c,
                                 (unsigned char) CLAMP (a * 255.0,
                                                        0.0, 255.0) };
      }

  img.data = px;
  img.width = N;
  img.height = N;
  img.mipmaps = 1;
  img.format = PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;

  tex = LoadTextureFromImage (img);
  g_free (px);
  if (tex.id == 0) return NULL;

  /* Nodes are drawn a few pixels across.  Without mipmaps, minifying a
     256px texture that far aliases into a shimmering dot on every
     camera move -- the artefact is motion, so a still screenshot hides
     it completely. */
  GenTextureMipmaps (&tex);
  SetTextureFilter (tex, TEXTURE_FILTER_TRILINEAR);

  r->orb_tex = grl_texture_new_from_handle (&tex);
  return r->orb_tex;
}

/* ── The glow ────────────────────────────────────────────────────── */

#define CMACS_GLOW_PX 128

/* A white radial falloff: a wide soft skirt plus a hot core.
 *
 * White on purpose -- the tint supplies the colour, so one texture
 * serves every node.  The profile lives in the ALPHA channel because
 * the glow pass blends additively (GL_SRC_ALPHA, GL_ONE): what lands in
 * the framebuffer is rgb * alpha, so alpha IS the intensity curve.
 *
 * The two-term shape matters.  A single power falloff is either all
 * skirt (a colour wash with no centre to anchor it to the node) or all
 * core (a dot indistinguishable from the node itself); the sum gives a
 * bright centre that visibly belongs to the node and a wide skirt that
 * reads as light bleeding off it. */
static GrlTexture *
ctx_glow_texture (CmacsLibregnumRenderCtx *r)
{
  const int N = CMACS_GLOW_PX;
  Color *px;
  Image img = { 0 };
  Texture2D tex;
  int x, y;

  if (!r) return NULL;
  if (r->glow_tex) return r->glow_tex;

  px = g_new0 (Color, (gsize) N * N);
  for (y = 0; y < N; y++)
    for (x = 0; x < N; x++)
      {
        double u = (2.0 * ((double) x + 0.5) / N) - 1.0;
        double v = (2.0 * ((double) y + 0.5) / N) - 1.0;
        double d = sqrt (u * u + v * v);
        double skirt, core, a;

        skirt = (d >= 1.0) ? 0.0 : pow (1.0 - d, 2.6);
        core  = (d >= 0.38) ? 0.0 : pow (1.0 - d / 0.38, 2.0);
        a = 0.72 * skirt + 0.28 * core;
        px[y * N + x] =
          (Color){ 255, 255, 255,
                   (unsigned char) CLAMP (a * 255.0, 0.0, 255.0) };
      }

  img.data = px;
  img.width = N;
  img.height = N;
  img.mipmaps = 1;
  img.format = PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;

  tex = LoadTextureFromImage (img);
  g_free (px);
  if (tex.id == 0) return NULL;

  /* Same reasoning as the orb: glows minify to a few pixels, and an
     unmipped texture shimmers there on every camera move. */
  GenTextureMipmaps (&tex);
  SetTextureFilter (tex, TEXTURE_FILTER_TRILINEAR);

  r->glow_tex = grl_texture_new_from_handle (&tex);
  return r->glow_tex;
}

gint
cmacs_libregnum_render_ctx_add_billboard_glow (CmacsLibregnumRenderCtx *r,
                                               float x, float y, float z,
                                               float size, guint32 rgba)
{
  CmacsBillboard b = { 0 };
  GrlTexture *tex;

  if (!r || !r->billboards) return -1;
  tex = ctx_glow_texture (r);
  if (!tex) return -1;

  b.x = x; b.y = y; b.z = z;
  b.size = size;
  b.rgba = rgba;
  /* The entry owns a ref; the context keeps its own in glow_tex. */
  b.tex = g_object_ref (tex);
  b.layer = 1;
  g_array_append_val (r->billboards, b);
  return (gint) r->billboards->len - 1;
}

void
cmacs_libregnum_render_ctx_clear_billboards (CmacsLibregnumRenderCtx *r)
{
  if (r && r->billboards) g_array_set_size (r->billboards, 0);
}

/* ── Particles ─────────────────────────────────────────────────────
 *
 * Built on LrgParticlePool and LrgParticleEmitter directly, NOT on
 * LrgParticleSystem.  The system looks like the obvious choice and is
 * not: its `draw' vfunc is a documented no-op that iterates the live
 * particles and does nothing with them, because rendering "depends on
 * the graphics backend".  A system-based implementation therefore
 * simulates correctly, reports a healthy live count, and draws not one
 * pixel -- which is exactly as broken as doing nothing, but much harder
 * to notice.
 *
 * Owning the pool costs one emission loop (the emitter already carries
 * the rate accumulator via should_emit) and buys the draw. */

/* Defined below, with the rest of the camera code. */
static Camera3D ctx_raylib_camera (CmacsLibregnumRenderCtx *r);

/* ── Background ────────────────────────────────────────────────────
 *
 * Generated into a texture and blitted, rather than drawn per frame:
 * a starfield recomputed every frame both costs more and, because the
 * randomness would differ each time, shimmers.  Regeneration is keyed
 * on kind + colours + path + size, so resizing the window regenerates
 * exactly once. */

/* A deterministic hash-based PRNG.  Deliberately not `rand': the same
 * viewport must produce the same sky every session, or a snapshot test
 * can never assert anything about it. */
static guint32
bg_rand (guint32 *state)
{
  guint32 x = (*state += 0x9E3779B9u);
  x = (x ^ (x >> 16)) * 0x21F0AAADu;
  x = (x ^ (x >> 15)) * 0x735A2D97u;
  return x ^ (x >> 15);
}

static double
bg_randf (guint32 *state)
{
  return (double) bg_rand (state) / (double) 0xFFFFFFFFu;
}

static void
bg_unpack (guint32 c, double *r, double *g, double *b)
{
  *r = (double) ((c >> 24) & 0xFF);
  *g = (double) ((c >> 16) & 0xFF);
  *b = (double) ((c >>  8) & 0xFF);
}

/* Smooth value noise on a coarse lattice, sampled bilinearly.  Enough
 * for a nebula and far cheaper than real Perlin. */
static double
bg_noise (guint32 seed, double x, double y)
{
  int x0 = (int) floor (x), y0 = (int) floor (y);
  double fx = x - x0, fy = y - y0;
  double v[4];
  int i;

  /* Smoothstep, so the lattice does not show as a grid. */
  fx = fx * fx * (3.0 - 2.0 * fx);
  fy = fy * fy * (3.0 - 2.0 * fy);

  for (i = 0; i < 4; i++)
    {
      guint32 st = seed ^ (guint32) ((x0 + (i & 1)) * 374761393)
                        ^ (guint32) ((y0 + (i >> 1)) * 668265263);
      v[i] = bg_randf (&st);
    }
  return (v[0] * (1 - fx) + v[1] * fx) * (1 - fy)
       + (v[2] * (1 - fx) + v[3] * fx) * fy;
}

/* Build the procedural background for the current kind at W x H. */
static void
bg_generate (CmacsLibregnumRenderCtx *r, int w, int h)
{
  Color *px;
  Image  img = { 0 };
  double tr, tg, tb, br, bg_, bb;
  int    x, y;

  if (w < 2 || h < 2) return;

  px = g_new0 (Color, (gsize) w * h);
  bg_unpack (r->bg_top, &tr, &tg, &tb);
  bg_unpack (r->bg_bottom, &br, &bg_, &bb);

  for (y = 0; y < h; y++)
    {
      double t = (double) y / (double) (h - 1);
      for (x = 0; x < w; x++)
        {
          double cr = tr, cg = tg, cb = tb;

          if (r->bg_kind != CMACS_LIBREGNUM_BG_SOLID)
            {
              cr = tr + (br - tr) * t;
              cg = tg + (bg_ - tg) * t;
              cb = tb + (bb - tb) * t;
            }
          px[y * w + x] = (Color){ (unsigned char) CLAMP (cr, 0.0, 255.0),
                                   (unsigned char) CLAMP (cg, 0.0, 255.0),
                                   (unsigned char) CLAMP (cb, 0.0, 255.0),
                                   255 };
        }
    }

  if (r->bg_kind == CMACS_LIBREGNUM_BG_NEBULA)
    {
      /* Two octaves of noise tinted toward the top colour, so the cloud
         belongs to the same palette as the gradient under it. */
      for (y = 0; y < h; y++)
        for (x = 0; x < w; x++)
          {
            double nx = (double) x / (double) w, ny = (double) y / (double) h;
            double n = bg_noise (0x51ED270Bu, nx * 5.0, ny * 5.0) * 0.65
                     + bg_noise (0x1B873593u, nx * 13.0, ny * 13.0) * 0.35;
            double k = CLAMP ((n - 0.45) * 2.2, 0.0, 1.0);
            Color *c = &px[y * w + x];
            c->r = (unsigned char) CLAMP (c->r + tr * k * 0.55, 0.0, 255.0);
            c->g = (unsigned char) CLAMP (c->g + tg * k * 0.55, 0.0, 255.0);
            c->b = (unsigned char) CLAMP (c->b + tb * k * 0.55, 0.0, 255.0);
          }
    }

  if (r->bg_kind == CMACS_LIBREGNUM_BG_STARFIELD
      || r->bg_kind == CMACS_LIBREGNUM_BG_NEBULA)
    {
      /* Density scales with area so a big viewport is not a sparse one. */
      guint32 st = 0xC2B2AE35u;
      int n = (w * h) / 1400, i;
      for (i = 0; i < n; i++)
        {
          int sx = (int) (bg_randf (&st) * w);
          int sy = (int) (bg_randf (&st) * h);
          double mag = bg_randf (&st);
          /* Cubed: mostly faint stars with a few bright ones, which is
             what makes a field read as depth rather than as noise. */
          double b = 90.0 + 165.0 * mag * mag * mag;
          Color *c;
          if (sx < 0 || sx >= w || sy < 0 || sy >= h) continue;
          c = &px[sy * w + sx];
          c->r = (unsigned char) CLAMP (c->r + b, 0.0, 255.0);
          c->g = (unsigned char) CLAMP (c->g + b, 0.0, 255.0);
          c->b = (unsigned char) CLAMP (c->b + b, 0.0, 255.0);
        }
    }

  img.data = px;
  img.width = w;
  img.height = h;
  img.mipmaps = 1;
  img.format = PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;

  if (r->bg_tex_ok) UnloadTexture (r->bg_tex);
  r->bg_tex = LoadTextureFromImage (img);
  r->bg_tex_ok = (r->bg_tex.id != 0);
  if (r->bg_tex_ok) SetTextureFilter (r->bg_tex, TEXTURE_FILTER_BILINEAR);
  r->bg_tex_w = w;
  r->bg_tex_h = h;
  g_free (px);
}

void
cmacs_libregnum_render_ctx_set_background_source (CmacsLibregnumRenderCtx *r,
                                                  CmacsLibregnumFrameSource fn,
                                                  gpointer user_data,
                                                  GDestroyNotify notify)
{
  if (!r) return;
  if (r->bg_src_notify && r->bg_src_data && r->bg_src_data != user_data)
    r->bg_src_notify (r->bg_src_data);
  r->bg_src = fn;
  r->bg_src_data = user_data;
  r->bg_src_notify = notify;
  /* Force the next frame to upload rather than trusting a generation
     counter from a source that has just been replaced. */
  r->bg_src_gen = 0;
  r->bg_src_have = FALSE;
}

/* Pull the newest frame from the registered source into `bg_tex'.
 *
 * UpdateTexture when the dimensions match, which is the common case and
 * costs one upload; a size change reallocates.  Returns FALSE when
 * there is nothing to draw yet -- the source has not produced a first
 * frame -- as opposed to nothing NEW, where the existing texture stands.
 *
 * The frame arrives in ARGB8888 == GL_BGRA byte order, which is what
 * gowl's frame sink takes and what the shm protocol documents.  raylib
 * has no BGRA pixel format, so the channels are swapped into a scratch
 * buffer before upload.
 *
 * Skipping that swap does NOT look obviously broken -- it silently
 * exchanges red and blue, which on a space scene reads as a perfectly
 * plausible picture in the wrong palette.  It cost an afternoon of
 * blaming the screensaver's --profile flag for an inversion that was
 * here. */
static gboolean
bg_pull_source (CmacsLibregnumRenderCtx *r)
{
  const void *px = NULL;
  int w = 0, h = 0;
  unsigned long long gen = 0;

  if (!r->bg_src) return r->bg_src_have;
  if (!r->bg_src (r->bg_src_data, &px, &w, &h, &gen) || !px || w <= 0 || h <= 0)
    return r->bg_src_have;
  if (r->bg_src_have && gen == r->bg_src_gen)
    return TRUE;                       /* already have this one */

  /* BGRA -> RGBA.  One pass over the frame, only when the generation
     changed, and the compiler vectorises it. */
  {
    gsize n = (gsize) w * (gsize) h, i;
    const guint32 *src = px;

    if (r->bg_src_rgba_n < n)
      {
        g_free (r->bg_src_rgba);
        r->bg_src_rgba = g_new (guint32, n);
        r->bg_src_rgba_n = n;
      }
    for (i = 0; i < n; i++)
      {
        guint32 p = src[i];
        r->bg_src_rgba[i] = (p & 0xFF00FF00u)
                            | ((p & 0x000000FFu) << 16)
                            | ((p >> 16) & 0x000000FFu);
      }
    px = r->bg_src_rgba;
  }

  if (!r->bg_tex_ok || r->bg_tex_w != w || r->bg_tex_h != h)
    {
      Image img = { 0 };
      img.data = (void *) px;
      img.width = w;
      img.height = h;
      img.mipmaps = 1;
      img.format = PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;
      if (r->bg_tex_ok) UnloadTexture (r->bg_tex);
      r->bg_tex = LoadTextureFromImage (img);   /* copies; img not owned */
      r->bg_tex_ok = (r->bg_tex.id != 0);
      if (r->bg_tex_ok) SetTextureFilter (r->bg_tex, TEXTURE_FILTER_BILINEAR);
      r->bg_tex_w = w;
      r->bg_tex_h = h;
    }
  else
    UpdateTexture (r->bg_tex, px);

  if (!r->bg_tex_ok) return FALSE;
  r->bg_src_gen = gen;
  r->bg_src_have = TRUE;
  return TRUE;
}

static void
bg_load_image (CmacsLibregnumRenderCtx *r)
{
  Image img;

  if (!r->bg_path || !r->bg_path[0]) return;
  img = LoadImage (r->bg_path);
  if (img.width <= 0 || img.height <= 0) { UnloadImage (img); return; }

  if (r->bg_tex_ok) UnloadTexture (r->bg_tex);
  r->bg_tex = LoadTextureFromImage (img);
  r->bg_tex_ok = (r->bg_tex.id != 0);
  if (r->bg_tex_ok) SetTextureFilter (r->bg_tex, TEXTURE_FILTER_BILINEAR);
  r->bg_tex_w = img.width;
  r->bg_tex_h = img.height;
  UnloadImage (img);
}

gboolean
cmacs_libregnum_render_ctx_set_background (CmacsLibregnumRenderCtx *r,
                                           CmacsLibregnumBackgroundKind kind,
                                           guint32 top, guint32 bottom,
                                           const char *path)
{
  if (!r) return FALSE;

  if (kind == CMACS_LIBREGNUM_BG_IMAGE && (!path || !path[0]))
    return FALSE;
  if (kind == CMACS_LIBREGNUM_BG_SOURCE && !r->bg_src)
    return FALSE;      /* nothing would ever be drawn */

  r->bg_kind = kind;
  r->bg_top = top;
  r->bg_bottom = bottom;
  g_free (r->bg_path);
  r->bg_path = (path && path[0]) ? g_strdup (path) : NULL;
  r->bg_dirty = TRUE;

  if (kind == CMACS_LIBREGNUM_BG_IMAGE)
    {
      /* Validate now rather than at frame time: the caller can then be
         told the path is bad while it still has somewhere to say so. */
      if (!g_file_test (r->bg_path, G_FILE_TEST_IS_REGULAR))
        {
          r->bg_kind = CMACS_LIBREGNUM_BG_NONE;
          return FALSE;
        }
    }
  return TRUE;
}

CmacsLibregnumBackgroundKind
cmacs_libregnum_render_ctx_get_background (CmacsLibregnumRenderCtx *r)
{
  return r ? r->bg_kind : CMACS_LIBREGNUM_BG_NONE;
}

/* Blit the background over the whole FBO.  Called after the clear and
 * before any 3D, so it sits behind everything. */
static void
ctx_draw_background (CmacsLibregnumRenderCtx *r, int w, int h)
{
  Rectangle src, dst;

  if (!r || r->bg_kind == CMACS_LIBREGNUM_BG_NONE) return;

  if (r->bg_kind == CMACS_LIBREGNUM_BG_SOURCE)
    {
      /* Re-pulled every frame: that is the whole point of a live
         source, and the generation check makes a repeat cheap. */
      if (!bg_pull_source (r)) return;
      r->bg_dirty = FALSE;
    }
  else if (r->bg_dirty
           || !r->bg_tex_ok
           || (r->bg_kind != CMACS_LIBREGNUM_BG_IMAGE
               && (r->bg_tex_w != w || r->bg_tex_h != h)))
    {
      if (r->bg_kind == CMACS_LIBREGNUM_BG_IMAGE) bg_load_image (r);
      else bg_generate (r, w, h);
      r->bg_dirty = FALSE;
    }
  if (!r->bg_tex_ok) return;

  if (r->bg_kind == CMACS_LIBREGNUM_BG_IMAGE
      || r->bg_kind == CMACS_LIBREGNUM_BG_SOURCE)
    {
      /* Cover fit: crop the longer axis rather than squashing it.  A
         wallpaper stretched to the viewport's aspect looks broken in a
         way a cropped one never does. */
      double sa = (double) r->bg_tex_w / (double) r->bg_tex_h;
      double da = (double) w / (double) h;
      double cw = r->bg_tex_w, ch = r->bg_tex_h;
      if (sa > da) cw = ch * da; else ch = cw / da;
      src = (Rectangle){ (float) ((r->bg_tex_w - cw) / 2.0),
                         (float) ((r->bg_tex_h - ch) / 2.0),
                         (float) cw, (float) ch };
    }
  else
    src = (Rectangle){ 0, 0, (float) r->bg_tex_w, (float) r->bg_tex_h };

  dst = (Rectangle){ 0, 0, (float) w, (float) h };
  DrawTexturePro (r->bg_tex, src, dst, (Vector2){ 0, 0 }, 0.0f, WHITE);
  rlDrawRenderBatchActive ();
}


/* 0xRRGGBBAA to the 0..1 floats the emitter wants. */
static void
rgba_to_floats (guint32 c, gfloat *r, gfloat *g, gfloat *b, gfloat *a)
{
  *r = (gfloat) ((c >> 24) & 0xFF) / 255.0f;
  *g = (gfloat) ((c >> 16) & 0xFF) / 255.0f;
  *b = (gfloat) ((c >>  8) & 0xFF) / 255.0f;
  *a = (gfloat) ( c        & 0xFF) / 255.0f;
}

/* The cap is a budget, not a target: particles are pure decoration and
 * must never be the reason a graph view drops frames. */
#define CMACS_PARTICLE_MAX (2048)
#define CMACS_PARTICLE_TEX (32)

/* A soft round dot, built by hand rather than with one of raylib's
 * GenImage* helpers so it does not depend on which of them this raylib
 * has.  Squared falloff: a linear one has a visible hard edge once it
 * is additively blended over itself. */
static void
ctx_particle_texture (CmacsLibregnumRenderCtx *r)
{
  const int S = CMACS_PARTICLE_TEX;
  Color *px;
  Image img = { 0 };
  int x, y;

  if (r->particle_tex_ok) return;

  px = g_new0 (Color, (gsize) S * S);
  for (y = 0; y < S; y++)
    for (x = 0; x < S; x++)
      {
        double dx = (x - (S - 1) / 2.0) / (S / 2.0);
        double dy = (y - (S - 1) / 2.0) / (S / 2.0);
        double d  = sqrt (dx * dx + dy * dy);
        double a  = (d >= 1.0) ? 0.0 : (1.0 - d) * (1.0 - d);
        px[y * S + x] = (Color){ 255, 255, 255, (unsigned char) (a * 255.0) };
      }

  img.data = px;
  img.width = S;
  img.height = S;
  img.mipmaps = 1;
  img.format = PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;

  r->particle_tex = LoadTextureFromImage (img);
  r->particle_tex_ok = (r->particle_tex.id != 0);
  if (r->particle_tex_ok)
    SetTextureFilter (r->particle_tex, TEXTURE_FILTER_BILINEAR);
  g_free (px);
}

static void
cmacs_particle_emitter_free (gpointer p)
{
  LrgParticleEmitter **e = p;
  if (e && *e) g_object_unref (*e);
}

static LrgParticlePool *
ctx_particles (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->particles_on) return NULL;
  if (!r->particle_pool)
    {
      r->particle_pool = lrg_particle_pool_new (CMACS_PARTICLE_MAX);
      if (!r->particle_pool) return NULL;
      r->particle_emitters =
        g_array_new (FALSE, TRUE, sizeof (LrgParticleEmitter *));
      g_array_set_clear_func (r->particle_emitters,
                              cmacs_particle_emitter_free);
    }
  return r->particle_pool;
}

/* Acquire one particle, initialise it from E, and hand it back.  NULL
 * when the pool is exhausted -- which is a budget being enforced, not
 * an error. */
static LrgParticle *
ctx_particle_spawn (CmacsLibregnumRenderCtx *r, LrgParticleEmitter *e)
{
  LrgParticle *pt = lrg_particle_pool_acquire (r->particle_pool);
  if (!pt) return NULL;
  lrg_particle_emitter_emit (e, pt);
  return pt;
}

void
cmacs_libregnum_render_ctx_particles_set_enabled (CmacsLibregnumRenderCtx *r,
                                                  gboolean on)
{
  if (!r) return;
  r->particles_on = on;
  if (!on)
    cmacs_libregnum_render_ctx_particles_clear (r);
}

gboolean
cmacs_libregnum_render_ctx_particles_enabled (CmacsLibregnumRenderCtx *r)
{
  return r && r->particles_on;
}

void
cmacs_libregnum_render_ctx_particles_clear (CmacsLibregnumRenderCtx *r)
{
  if (!r) return;
  if (r->particle_emitters) g_array_set_size (r->particle_emitters, 0);
  if (r->particle_pool) lrg_particle_pool_clear (r->particle_pool);
}

gboolean
cmacs_libregnum_render_ctx_particles_add_emitter (CmacsLibregnumRenderCtx *r,
                                                  float x, float y, float z,
                                                  float radius, float rate,
                                                  guint32 rgba_start,
                                                  guint32 rgba_end,
                                                  float size, float life,
                                                  float speed)
{
  LrgParticlePool *pool = ctx_particles (r);
  LrgParticleEmitter *e;
  gfloat cr, cg, cb, ca;

  if (!pool) return FALSE;

  e = lrg_particle_emitter_new ();
  if (!e) return FALSE;

  lrg_particle_emitter_set_position (e, x, y, z);
  /* From a sphere's surface, drifting outward: an emitter anchored at a
   * point looks like a fountain, which is wrong for a node meant to feel
   * ambient rather than active. */
  lrg_particle_emitter_set_emission_shape (e, LRG_EMISSION_SHAPE_CIRCLE);
  lrg_particle_emitter_set_shape_radius (e, radius);
  lrg_particle_emitter_set_emission_rate (e, rate);
  lrg_particle_emitter_set_initial_speed (e, speed * 0.35f, speed);
  lrg_particle_emitter_set_initial_lifetime (e, life * 0.6f, life);
  lrg_particle_emitter_set_initial_size (e, size * 0.5f, size);

  rgba_to_floats (rgba_start, &cr, &cg, &cb, &ca);
  lrg_particle_emitter_set_start_color (e, cr, cg, cb, ca);
  rgba_to_floats (rgba_end, &cr, &cg, &cb, &ca);
  lrg_particle_emitter_set_end_color (e, cr, cg, cb, ca);

  g_array_append_val (r->particle_emitters, e);
  return TRUE;
}

gboolean
cmacs_libregnum_render_ctx_particles_burst (CmacsLibregnumRenderCtx *r,
                                            float x, float y, float z,
                                            guint count,
                                            guint32 rgba_start,
                                            guint32 rgba_end,
                                            float size, float life,
                                            float speed)
{
  LrgParticlePool *pool = ctx_particles (r);
  gfloat cr, cg, cb, ca;
  guint i, made = 0;

  if (!pool) return FALSE;

  /* One reusable emitter at rate 0: a burst is emission on demand, and
   * an emitter with a rate parked in the ambient list would spray
   * forever. */
  if (!r->burst_emitter)
    {
      r->burst_emitter = lrg_particle_emitter_new ();
      if (!r->burst_emitter) return FALSE;
      lrg_particle_emitter_set_emission_rate (r->burst_emitter, 0.0f);
      lrg_particle_emitter_set_emission_shape (r->burst_emitter,
                                               LRG_EMISSION_SHAPE_CIRCLE);
    }

  lrg_particle_emitter_set_position (r->burst_emitter, x, y, z);
  lrg_particle_emitter_set_shape_radius (r->burst_emitter, size);
  lrg_particle_emitter_set_initial_speed (r->burst_emitter,
                                          speed * 0.5f, speed);
  lrg_particle_emitter_set_initial_lifetime (r->burst_emitter,
                                             life * 0.5f, life);
  lrg_particle_emitter_set_initial_size (r->burst_emitter,
                                         size * 0.5f, size);

  rgba_to_floats (rgba_start, &cr, &cg, &cb, &ca);
  lrg_particle_emitter_set_start_color (r->burst_emitter, cr, cg, cb, ca);
  rgba_to_floats (rgba_end, &cr, &cg, &cb, &ca);
  lrg_particle_emitter_set_end_color (r->burst_emitter, cr, cg, cb, ca);

  for (i = 0; i < count; i++)
    if (ctx_particle_spawn (r, r->burst_emitter)) made++;
    else break;

  return made > 0;
}

guint
cmacs_libregnum_render_ctx_particles_count (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->particle_pool) return 0;
  return lrg_particle_pool_get_alive_count (r->particle_pool);
}

/* Advance and draw.  Called from inside the 3D layer of the FBO pass --
 * the only place with a bound camera and an open render target. */
static void
ctx_particles_step_and_draw (CmacsLibregnumRenderCtx *r)
{
  gint64  now;
  gdouble dt;
  guint   i, n = 0;
  LrgParticle *arr;
  Camera3D cam;

  if (!r || !r->particles_on || !r->particle_pool) return;

  now = g_get_monotonic_time ();
  dt  = r->particles_last_us
          ? (gdouble) (now - r->particles_last_us) / 1e6 : 0.0;
  r->particles_last_us = now;
  /* Clamp: a view that was idle for a minute must not integrate a
   * minute of motion in one frame and fling every particle away. */
  if (dt < 0.0)  dt = 0.0;
  if (dt > 0.1)  dt = 0.1;

  /* Emit.  `should_emit' carries the emitter's own fractional rate
   * accumulator, so a 6/second emitter really does average six. */
  if (r->particle_emitters)
    for (i = 0; i < r->particle_emitters->len; i++)
      {
        LrgParticleEmitter *e =
          g_array_index (r->particle_emitters, LrgParticleEmitter *, i);
        if (!e) continue;
        lrg_particle_emitter_update (e, (gfloat) dt);
        while (lrg_particle_emitter_should_emit (e))
          if (!ctx_particle_spawn (r, e)) break;
      }

  lrg_particle_pool_update_all (r->particle_pool, (gfloat) dt);

  arr = lrg_particle_pool_get_particles (r->particle_pool, &n);
  if (!arr || n == 0) return;

  ctx_particle_texture (r);
  if (!r->particle_tex_ok) return;

  cam = ctx_raylib_camera (r);

  /* Additive, and NOT writing depth: particles are a glow over the
   * scene, and letting them into the depth buffer makes each one punch
   * a hole the ones behind it cannot draw through. */
  rlDrawRenderBatchActive ();
  rlDisableDepthMask ();
  BeginBlendMode (BLEND_ADDITIVE);

  for (i = 0; i < n; i++)
    {
      LrgParticle *pt = &arr[i];
      Color c;

      if (!pt->alive) continue;
      c = (Color){ (unsigned char) (CLAMP (pt->color_r, 0.0f, 1.0f) * 255.0f),
                   (unsigned char) (CLAMP (pt->color_g, 0.0f, 1.0f) * 255.0f),
                   (unsigned char) (CLAMP (pt->color_b, 0.0f, 1.0f) * 255.0f),
                   (unsigned char) (CLAMP (pt->color_a, 0.0f, 1.0f) * 255.0f) };
      DrawBillboard (cam, r->particle_tex,
                     (Vector3){ pt->position_x, pt->position_y,
                                pt->position_z },
                     pt->size, c);
    }

  EndBlendMode ();
  rlDrawRenderBatchActive ();
  rlEnableDepthMask ();
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

/* Move an existing node's pick box.  A scene whose drawables are
   mutated in place (an animated force-directed layout, a dragged
   node) must call this too, or picking and labelling keep pointing at
   where the node used to be. */
void
cmacs_libregnum_render_ctx_move_node (CmacsLibregnumRenderCtx *r, gint id,
                                      float x, float y, float z)
{
  CmacsNode *n;

  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return;
  n = &g_array_index (r->nodes, CmacsNode, id);
  n->x = x; n->y = y; n->z = z;
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

/* ── Spatial navigation ────────────────────────────────────────────
 * Nearest node in a screen-space direction from another node.  Must
 * live in C: doing it from Lisp means one projection call per candidate
 * per keypress, against a camera that may be mid-tween. */

gint
cmacs_libregnum_render_ctx_nearest_in_direction (CmacsLibregnumRenderCtx *r,
                                                 gint from,
                                                 double dx, double dy,
                                                 int vw, int vh,
                                                 double cone_cos,
                                                 gboolean visible_only)
{
  CmacsNode *src;
  double ox = 0, oy = 0, dlen;
  double best = 0;
  gint best_id = -1;
  guint i;

  if (!r || !r->nodes || from < 0 || (guint) from >= r->nodes->len)
    return -1;
  if (vw <= 0 || vh <= 0) return -1;

  dlen = sqrt (dx * dx + dy * dy);
  if (dlen < 1e-9) return -1;
  dx /= dlen; dy /= dlen;

  src = &g_array_index (r->nodes, CmacsNode, (guint) from);
  if (!cmacs_libregnum_render_ctx_project (r, src->x, src->y, src->z,
                                           vw, vh, &ox, &oy))
    return -1;

  for (i = 0; i < r->nodes->len; i++)
    {
      CmacsNode *n = &g_array_index (r->nodes, CmacsNode, i);
      double sx = 0, sy = 0, vx, vy, len, c, score;

      if ((gint) i == from) continue;
      if (visible_only && !ctx_point_near_side (r, n->x, n->y, n->z)) continue;
      if (!cmacs_libregnum_render_ctx_project (r, n->x, n->y, n->z,
                                               vw, vh, &sx, &sy))
        continue;

      vx = sx - ox;
      vy = sy - oy;
      len = sqrt (vx * vx + vy * vy);
      /* Nodes drawn on top of each other are not "to the left of" one
         another in any useful sense. */
      if (len < 4.0) continue;

      c = (vx * dx + vy * dy) / len;
      if (c < cone_cos) continue;

      /* Prefer near and well-aligned; the cubed cosine makes alignment
         matter more than raw distance, which is what "the node over
         there" means when two candidates are similarly far. */
      score = len / (c * c * c);
      /* Ties broken by lower id so repeated presses are deterministic. */
      if (best_id < 0 || score < best)
        { best = score; best_id = (gint) i; }
    }
  return best_id;
}

gboolean
cmacs_libregnum_render_ctx_node_onscreen_p (CmacsLibregnumRenderCtx *r,
                                            gint id, int vw, int vh,
                                            double margin_px)
{
  CmacsNode *n;
  double sx = 0, sy = 0;

  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return FALSE;
  if (vw <= 0 || vh <= 0) return FALSE;
  n = &g_array_index (r->nodes, CmacsNode, (guint) id);
  if (!cmacs_libregnum_render_ctx_project (r, n->x, n->y, n->z,
                                           vw, vh, &sx, &sy))
    return FALSE;
  return (sx >= margin_px && sy >= margin_px
          && sx <= (double) vw - margin_px
          && sy <= (double) vh - margin_px);
}

/* ── Node flags: search matches, dimming, pins ─────────────────────
 * Deliberately separate from `selected', which is a single index and is
 * already load-bearing (highlight box, focus_node, editor multi-select).
 * A match set is a different concept and must coexist with a selection. */

void
cmacs_libregnum_render_ctx_set_node_flags (CmacsLibregnumRenderCtx *r,
                                           gint id, guint flags)
{
  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return;
  g_array_index (r->nodes, CmacsNode, (guint) id).flags = flags;
}

guint
cmacs_libregnum_render_ctx_get_node_flags (CmacsLibregnumRenderCtx *r,
                                           gint id)
{
  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return 0;
  return g_array_index (r->nodes, CmacsNode, (guint) id).flags;
}

void
cmacs_libregnum_render_ctx_clear_node_flags (CmacsLibregnumRenderCtx *r,
                                             guint mask)
{
  guint i;

  if (!r || !r->nodes) return;
  for (i = 0; i < r->nodes->len; i++)
    g_array_index (r->nodes, CmacsNode, i).flags &= ~mask;
}

void
cmacs_libregnum_render_ctx_set_match_set (CmacsLibregnumRenderCtx *r,
                                          const gint *ids, gsize n,
                                          gboolean dim_rest)
{
  guint i;
  gsize j;

  if (!r || !r->nodes) return;

  /* One call per keystroke instead of one per node. */
  for (i = 0; i < r->nodes->len; i++)
    {
      CmacsNode *nd = &g_array_index (r->nodes, CmacsNode, i);
      nd->flags &= ~(CMACS_LIBREGNUM_NODE_MATCH | CMACS_LIBREGNUM_NODE_DIM);
      if (dim_rest && n > 0) nd->flags |= CMACS_LIBREGNUM_NODE_DIM;
    }
  for (j = 0; j < n; j++)
    {
      gint id = ids[j];
      if (id < 0 || (guint) id >= r->nodes->len) continue;
      {
        CmacsNode *nd = &g_array_index (r->nodes, CmacsNode, (guint) id);
        nd->flags |= CMACS_LIBREGNUM_NODE_MATCH;
        nd->flags &= ~CMACS_LIBREGNUM_NODE_DIM;
      }
    }
}

/* ── In-scene node labels ──────────────────────────────────────────
 * A 2D screen-space pass drawn inside the FBO bracket, after the 3D
 * scene.  Replaces (for contexts that opt in) the pgtk-only cairo
 * overlay, so `emacs --lrg' gets labels from the same code path.
 *
 * Two things here are load-bearing and easy to get wrong:
 *
 *  - Orientation.  The colour attachment is bottom-up in memory
 *    (glReadPixels' origin is lower-left) and the pgtk blit flips it at
 *    paint time, which invites a compensating flip here.  Do NOT add
 *    one: BeginTextureMode installs a projection that already makes
 *    raylib's 2D drawing top-down in the texture's own space -- the
 *    same orientation GetWorldToScreenEx reports.  Flipping mirrors
 *    every label about the middle of the viewport, so it lands below
 *    its node instead of above.
 *
 *  - The anchor is computed in SCREEN space, not world space, unlike
 *    the legacy `label_at'.  That one offsets by the node's half-height
 *    along world +Y, which projects to nothing in a top-down or
 *    front-facing orthographic view -- the label lands on top of the
 *    node.  Projecting the node's screen radius instead is correct in
 *    perspective and orthographic alike. */

typedef struct
{
  guint  id;
  float  sx, sy;        /* projected centre, FBO space */
  float  rpx;           /* projected radius in pixels */
  float  priority;      /* higher wins a collision */
  const char *text;
} LabelCand;

static int
label_cand_cmp (const void *pa, const void *pb)
{
  const LabelCand *a = pa, *b = pb;

  if (a->priority > b->priority) return -1;
  if (a->priority < b->priority) return 1;
  /* Total order, so the frame-to-frame result does not flicker. */
  return (a->id < b->id) ? -1 : (a->id > b->id) ? 1 : 0;
}

static void
ctx_draw_node_labels (CmacsLibregnumRenderCtx *r)
{
  guint nc, i, ncand = 0, drawn = 0;
  int vw, vh, fs, cap;
  LabelCand *cand;
  Camera3D cam;
  float rightx, righty, rightz;
  /* Accepted label rectangles, for the greedy overlap test. */
  float *taken;
  guint ntaken = 0;

  if (!r || !r->nodes) return;
  nc = r->nodes->len;
  if (nc == 0) return;

  vw = r->width;
  vh = r->height;
  if (vw <= 0 || vh <= 0) return;

  fs = (r->label_px > 0) ? r->label_px : 13;
  cap = (r->label_max > 0) ? r->label_max : 120;

  cam = ctx_raylib_camera (r);

  /* Camera right vector = normalize (forward x up).  Used to turn a
     node's world radius into a pixel radius by projecting one point on
     its silhouette. */
  {
    float fx = cam.target.x - cam.position.x;
    float fy = cam.target.y - cam.position.y;
    float fz = cam.target.z - cam.position.z;
    float len;
    rightx = fy * cam.up.z - fz * cam.up.y;
    righty = fz * cam.up.x - fx * cam.up.z;
    rightz = fx * cam.up.y - fy * cam.up.x;
    len = sqrtf (rightx * rightx + righty * righty + rightz * rightz);
    if (len < 1e-6f) { rightx = 1.0f; righty = 0.0f; rightz = 0.0f; }
    else { rightx /= len; righty /= len; rightz /= len; }
  }

  cand  = g_new0 (LabelCand, nc);
  taken = g_new0 (float, (gsize) cap * 4);

  for (i = 0; i < nc; i++)
    {
      CmacsNode *n = &g_array_index (r->nodes, CmacsNode, i);
      double sx = 0, sy = 0, ex = 0, ey = 0;
      float extent;

      if (!n->name || !n->name[0]) continue;
      if (!cmacs_libregnum_render_ctx_label_visible_p (r, i)) continue;
      /* Globe contexts hide labels on the far side of the sphere. */
      if (!ctx_point_near_side (r, n->x, n->y, n->z)) continue;
      if (!cmacs_libregnum_render_ctx_project (r, n->x, n->y, n->z,
                                               vw, vh, &sx, &sy))
        continue;
      if (sx < -64 || sy < -64 || sx > vw + 64 || sy > vh + 64) continue;

      extent = fmaxf (n->hw, fmaxf (n->hh, n->hd));
      if (!cmacs_libregnum_render_ctx_project (r,
                                               n->x + rightx * extent,
                                               n->y + righty * extent,
                                               n->z + rightz * extent,
                                               vw, vh, &ex, &ey))
        { ex = sx; ey = sy; }

      cand[ncand].id   = i;
      cand[ncand].sx   = (float) sx;
      cand[ncand].sy   = (float) sy;
      cand[ncand].rpx  = (float) fabs (ex - sx);
      cand[ncand].text = n->name;
      /* Selection and hover always win, then a match or a neighbour of
         the selection, and only then size (which favours hubs) and
         nearness.
         The flagged tiers matter because of the cap: eligibility alone
         is not enough.  A note linked to the selection is small, so on
         size it loses to every hub in the scene and its label is
         dropped -- which is a highlighted node whose name you still
         cannot read, exactly what highlighting was for. */
      cand[ncand].priority =
        (r->selected == (gint) i) ? 1e9f
        : (r->hovered == (gint) i) ? 5e8f
        : (n->flags & CMACS_LIBREGNUM_NODE_MATCH) ? 4e8f
        : (n->flags & CMACS_LIBREGNUM_NODE_NEIGHBOUR) ? 3e8f
        : (n->hw + n->hh + n->hd) * 1000.0f
          - (float) cmacs_libregnum_render_ctx_camera_distance (r);
      ncand++;
    }

  if (ncand > 1)
    qsort (cand, ncand, sizeof (LabelCand), label_cand_cmp);

  rlDisableDepthTest ();

  /* Screen-space emphasis rings, drawn before the text so the labels
     stay on top.  A ring scales with the node's projected size, so it
     reads the same whether you are zoomed right in or looking at the
     whole graph -- which a fixed-size world-space marker does not. */
  if (r->emphasis_rings)
    for (i = 0; i < ncand; i++)
      {
        LabelCand *c = &cand[i];
        gboolean sel = (r->selected == (gint) c->id);
        gboolean hov = (r->hovered == (gint) c->id);
        guint flags = g_array_index (r->nodes, CmacsNode, c->id).flags;
        float rr;

        if (!sel && !hov && !(flags & CMACS_LIBREGNUM_NODE_MATCH)) continue;

        rr = MAX (c->rpx, 3.0f);
        {
          g_autoptr (GrlVector2) at = grl_vector2_new (c->sx, c->sy);
          if (sel)
            {
              /* Two rings: a soft outer glow and a crisp inner one, so
                 the selection is unmistakable against any background. */
              g_autoptr (GrlColor) glow = grl_color_new (255, 235, 120, 60);
              g_autoptr (GrlColor) edge = grl_color_new (255, 235, 120, 235);
              grl_draw_ring (at, rr + 3.0f, rr + 11.0f, 0.0f, 360.0f, 40, glow);
              grl_draw_ring (at, rr + 3.0f, rr + 5.0f, 0.0f, 360.0f, 40, edge);
            }
          else if (hov)
            {
              g_autoptr (GrlColor) edge = grl_color_new (170, 220, 255, 190);
              grl_draw_ring (at, rr + 2.0f, rr + 3.5f, 0.0f, 360.0f, 32, edge);
            }
          else
            {
              /* A search hit: the accent colour again, thinner. */
              g_autoptr (GrlColor) edge = grl_color_new (255, 210, 74, 200);
              grl_draw_ring (at, rr + 2.0f, rr + 4.0f, 0.0f, 360.0f, 32, edge);
            }
        }
      }

  for (i = 0; i < ncand && drawn < (guint) cap; i++)
    {
      LabelCand *c = &cand[i];
      float tw, th, lx, ly, y_fbo;
      gboolean collides = FALSE;
      guint j;

      if (r->label_font != NULL)
        {
          g_autoptr (GrlVector2) m =
            grl_font_measure_text (r->label_font, c->text, (gfloat) fs, 1.0f);
          tw = m ? grl_vector2_get_x (m) : (float) (fs * 2);
          th = m ? grl_vector2_get_y (m) : (float) fs;
        }
      else
        {
          tw = (float) grl_measure_text (c->text, fs);
          th = (float) fs;
        }

      /* Centre over the node, just above its silhouette. */
      lx = c->sx - tw * 0.5f;
      ly = c->sy - (c->rpx + 6.0f) - th;

      if (r->label_declutter)
        {
          for (j = 0; j < ntaken; j++)
            {
              const float *t = &taken[j * 4];
              if (lx < t[0] + t[2] && lx + tw > t[0]
                  && ly < t[1] + t[3] && ly + th > t[1])
                { collides = TRUE; break; }
            }
          /* Selection and hover are never suppressed -- the whole point
             of pointing at something is to read its name. */
          if (collides
              && r->selected != (gint) c->id
              && r->hovered != (gint) c->id)
            continue;
          if (ntaken < (guint) cap)
            {
              float *t = &taken[ntaken * 4];
              t[0] = lx; t[1] = ly; t[2] = tw; t[3] = th;
              ntaken++;
            }
        }

      /* No flip.  The colour attachment is bottom-up in memory, but
         BeginTextureMode installs a projection that makes raylib's 2D
         drawing top-down in the texture's own space -- the same
         orientation GetWorldToScreenEx reports and the blit displays.
         Flipping here would mirror the label about the middle of the
         viewport, putting it below its node instead of above (which is
         precisely what cmacs-roamgraph-test-inscene-label-is-above-its-node
         exists to catch, and did). */
      y_fbo = ly;

      /* Backdrop pill.  Over a dense graph the edges run straight
         through the text and it becomes unreadable; a translucent
         plate behind each label costs one quad and fixes it. */
      if (r->label_backdrop)
        {
          /* Padding scales with the text: at a 22px label the old flat
             4px inset left the glyphs touching the plate edge, so the
             plate stopped reading as a plate and the text stopped
             separating from what was behind it. */
          float padx = 4.0f + (float) fs * 0.18f;
          float pady = 2.0f + (float) fs * 0.10f;
          g_autoptr (GrlRectangle) rect =
            grl_rectangle_new (lx - padx, y_fbo - pady,
                               tw + padx * 2.0f, th + pady * 2.0f);
          /* Opaque.  The plate exists precisely for the case where the
             scene behind the text is bright and busy -- a ring of a
             few hundred nodes with a thousand links over it -- and any
             translucency there puts that texture straight through the
             glyphs.  Legibility is the whole job; subtlety is not. */
          g_autoptr (GrlColor) bgc =
            (r->selected == (gint) c->id)
            ? grl_color_new (62, 55, 20, 255)
            : grl_color_new (10, 11, 16, 250);
          grl_draw_rectangle_rounded (rect, 0.45f, 6, bgc);
        }

      {
        g_autoptr (GrlColor) sh = grl_color_new (0, 0, 0, 200);
        g_autoptr (GrlColor) fg =
          (r->selected == (gint) c->id)
          ? grl_color_new (255, 240, 150, 255)
          : grl_color_new (248, 250, 255, 255);

        if (r->label_font != NULL)
          {
            if (r->label_shadow)
              {
                g_autoptr (GrlVector2) ps =
                  grl_vector2_new (lx + 1.0f, y_fbo + 1.0f);
                grl_draw_text_ex (r->label_font, c->text, ps,
                                  (gfloat) fs, 1.0f, sh);
              }
            {
              g_autoptr (GrlVector2) pf = grl_vector2_new (lx, y_fbo);
              grl_draw_text_ex (r->label_font, c->text, pf,
                                (gfloat) fs, 1.0f, fg);
            }
          }
        else
          {
            if (r->label_shadow)
              grl_draw_text (c->text, (int) lx + 1, (int) y_fbo + 1, fs, sh);
            grl_draw_text (c->text, (int) lx, (int) y_fbo, fs, fg);
          }
      }
      drawn++;
    }

  rlEnableDepthTest ();
  g_free (cand);
  g_free (taken);
}

/* Aim the camera at node ID: target = node center, position backed off
 * along the current view direction by a distance scaled to node size.
 * Animated by step_focus() over subsequent frames. */
void
cmacs_libregnum_render_ctx_set_focus_policy (CmacsLibregnumRenderCtx *r,
                                             gboolean on_click,
                                             double context_frac)
{
  if (!r) return;
  r->click_focus = on_click;
  r->focus_context = (context_frac > 0.0) ? context_frac : 0.0;
}

gboolean
cmacs_libregnum_render_ctx_click_focuses (CmacsLibregnumRenderCtx *r)
{
  return r && r->click_focus;
}

void
cmacs_libregnum_render_ctx_set_drag_nodes (CmacsLibregnumRenderCtx *r,
                                           gboolean on)
{
  if (r) r->drag_nodes = on;
}

gboolean
cmacs_libregnum_render_ctx_drag_nodes (CmacsLibregnumRenderCtx *r)
{
  return r && r->drag_nodes;
}

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
  /* A node's own size says nothing about the scale of the scene around
     it, so in a large graph that distance frames one dot and none of
     its surroundings.  Where a scene has asked for context, keep at
     least that fraction of the whole extent between camera and node. */
  if (r->focus_context > 0.0)
    {
      float mnx = 0, mny = 0, mnz = 0, mxx = 0, mxy = 0, mxz = 0;
      guint i, cnt = r->nodes->len;
      for (i = 0; i < cnt; i++)
        {
          CmacsNode *m = &g_array_index (r->nodes, CmacsNode, i);
          if (i == 0)
            { mnx = mxx = m->x; mny = mxy = m->y; mnz = mxz = m->z; }
          else
            {
              mnx = fminf (mnx, m->x); mxx = fmaxf (mxx, m->x);
              mny = fminf (mny, m->y); mxy = fmaxf (mxy, m->y);
              mnz = fminf (mnz, m->z); mxz = fmaxf (mxz, m->z);
            }
        }
      {
        float se = fmaxf (mxx - mnx, fmaxf (mxy - mny, mxz - mnz));
        float floor_d = se * (float) r->focus_context;
        if (floor_d > dist) dist = floor_d;
      }
    }
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
                                      const char *so_path,
                                      const char *const *argv,
                                      char **error_msg)
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

  /* Apply the per-instance CLI-style args (LrgConfigurable) BEFORE startup,
   * matching lrgldr/lrg_game_run_standalone ordering: the game stashes them in
   * apply_args and consumes them during startup (post_startup). A bad arg is a
   * warning, not a hard failure (same as the reference launcher). */
  if (argv != NULL)
    {
      g_autoptr (GError) args_err = NULL;
      if (!lrg_game_template_apply_args (game, argv, &args_err))
        g_warning ("cmacs-libregnum: game args rejected: %s",
                   args_err != NULL ? args_err->message : "unknown");
    }

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

  /* The hosted game has no window, so tell it the FBO size up front (its
   * cached default is 1280x720); otherwise it renders at that size regardless
   * of the actual view/monitor.  Resizes are handled in ..._ctx_resize. */
  lrg_game_template_set_window_size (game, r->width, r->height);
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

  if (r->game_owned)
    g_clear_object (&r->game);     /* directly owned (no loaded_game) */
  else
    r->game = NULL;                /* owned by loaded_game */
  r->game_owned = FALSE;
  g_clear_object (&r->game_host);

  if (r->loaded_game)
    {
      lrg_loaded_game_unload (r->loaded_game);
      g_clear_object (&r->loaded_game);
    }

  r->game_mode = FALSE;
}

/* Host an already-constructed LrgGameTemplate (transfer full) in this render
 * ctx -- the elisp-game path, which builds its own template instead of loading
 * a `.so'.  Mirrors cmacs_libregnum_render_ctx_load_game's host/input/startup
 * setup, but owns `game' directly (game_owned) since there is no loaded_game. */
gboolean
cmacs_libregnum_render_ctx_host_game (CmacsLibregnumRenderCtx *r,
                                      void *game_template,
                                      char **error_msg)
{
  GError           *error = NULL;
  LrgGameTemplate  *game = game_template;
  CmacsFboGameHost *host;

  if (!r || !game)
    {
      g_clear_object (&game);
      return FALSE;
    }
  if (r->game_mode) cmacs_libregnum_render_ctx_unload_game (r);

  host = cmacs_fbo_game_host_new (r);

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
      g_object_unref (game);
      return FALSE;
    }

  r->game       = game;           /* owned directly */
  r->game_owned = TRUE;
  r->game_host  = LRG_GAME_HOST (host);
  r->game_mode  = TRUE;
  lrg_game_template_set_window_size (game, r->width, r->height);
  return TRUE;
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

/* Compute the rotation to hand grl_model_draw_ex for an editor model.
 *
 * Two problems are solved together so they cannot disagree:
 *  1. The draw call takes a SINGLE axis+angle, but a node carries Euler
 *     XYZ.  The old code hard-coded the Y axis and passed only em->ry, so
 *     X-/Z-axis rotations (the right-click "Rotate" menu, the rotate gizmo
 *     about those axes) were stored on the node but never shown.
 *  2. draw_ex rotates about the MODEL ORIGIN.  A CAD part is usually
 *     modelled far from its origin, so rotating made it orbit that point
 *     and swing out of its (axis-aligned) selection box instead of turning
 *     in place.
 *
 * Both derive from ONE rotation matrix R built from the Euler angles: the
 * draw axis+angle comes from R (via quaternion), and the position offset
 * `OFF = C - R*C` re-pivots the rotation about the part's own (already
 * scaled) centre C so it spins in place.  AXIS is transfer-full; *DEG is
 * degrees; OFF[3] is added to the node location by the caller. */
static GrlVector3 *
cmacs_editor_rotation_for_draw (float rx, float ry, float rz,
                                float cx, float cy, float cz,
                                float *deg, float off[3])
{
  g_autoptr (GrlMatrix) rot = grl_matrix_new_rotate_xyz (rx, ry, rz);
  GrlVector3 *axis = grl_vector3_new (0.0f, 1.0f, 0.0f);
  float ang = 0.0f;
  float rcx = cx, rcy = cy, rcz = cz;
  if (rot)
    {
      g_autoptr (GrlQuaternion) q = grl_quaternion_new_from_matrix (rot);
      /* R * C (column-major layout: row 0 = m0,m4,m8). */
      rcx = rot->m0 * cx + rot->m4 * cy + rot->m8  * cz;
      rcy = rot->m1 * cx + rot->m5 * cy + rot->m9  * cz;
      rcz = rot->m2 * cx + rot->m6 * cy + rot->m10 * cz;
      if (q)
        grl_quaternion_to_axis_angle (q, axis, &ang);
    }
  /* An identity rotation yields a degenerate (0,0,0) axis; keep a valid
   * axis so draw_ex's MatrixRotate does not produce NaNs. */
  if (axis->x == 0.0f && axis->y == 0.0f && axis->z == 0.0f)
    axis->y = 1.0f;
  if (deg)
    *deg = ang * 57.2957795f;
  if (off)
    {
      off[0] = cx - rcx;
      off[1] = cy - rcy;
      off[2] = cz - rcz;
    }
  return axis;
}

gboolean
cmacs_libregnum_render_ctx_render_to_bgra (CmacsLibregnumRenderCtx *r,
                                           unsigned char *dst,
                                           int dst_w, int dst_h)
{
  /* DST may be NULL: callers that only want the scene rendered INTO the FBO
     (the lrg overlay, which then draws fbo.texture directly) pass NULL to
     skip the glReadPixels copy.  */
  if (!r || !r->fbo_valid) return FALSE;
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
      if (dst)
        glReadPixels (0, 0, r->width, r->height,
                      GL_BGRA, GL_UNSIGNED_BYTE, dst);
      lrg_game_host_end_frame (r->game_host);     /* EndTextureMode */
      return TRUE;
    }

  /* 2D image-display mode: draw the composited image (checkerboard + quad +
   * overlay) instead of the 3D scene.  Same FBO/readback bracket as above. */
  if (r->image_mode)
    return ctx_render_image (r, dst);

  /* 2D chart mode (cmacs-calculator): draw an LrgChart widget instead of the
   * 3D scene.  Same FBO/readback bracket as above. */
  if (r->chart_mode)
    return ctx_render_chart (r, dst);

  /* Advance the camera focus tween (if any) before drawing this
   * frame; the view re-requests a redraw while focus_active is true. */
  ctx_step_focus (r);

  /* NOTE: we deliberately do NOT open the renderer's FRAME bracket
   * here -- only its LAYER bracket.  `lrg_renderer_begin_frame' /
   * `end_frame' forward to lrg_window_begin_frame / end_frame whenever
   * the renderer has a window, and those wrap raylib's BeginDrawing /
   * EndDrawing.  EndDrawing presents + paces the *hidden* offscreen
   * window: glfwSwapBuffers (vsync-blocks), WaitTime (enforces the
   * window's 60 FPS SetTargetFPS cap -- ~16 ms of sleep per call), and
   * glfwPollEvents.  For an FBO-only readback path that never shows a
   * window, all three are pure latency -- the WaitTime cap alone was
   * throttling every scene update to <=60 FPS and adding up to a frame
   * of sleep to each interactive redraw.
   *
   * This used to say exactly that while calling the RENDERER's frame
   * bracket two hundred lines below, which forwards to the window's.
   * The renderer is only windowless when there is no shared window --
   * and there almost always is one -- so every offscreen frame paid a
   * full windowed present.  A two-node scene measured 16.7 ms/frame:
   * the 60 FPS period, i.e. essentially all sleep.  With a repeating
   * 30 ms animation timer driving redraws from Lisp that is most of
   * the main thread gone, and Emacs stops responding.  Offscreen rendering needs
   * only BeginTextureMode/EndTextureMode + a current GL context; the
   * default render batch is initialised by InitWindow and flushed by
   * EndTextureMode, so no BeginDrawing is required. */
  BeginTextureMode (r->fbo);
  {
    Color bg = (Color){ 16, 16, 21, 255 };
    ClearBackground (bg);
    /* After the clear, before anything 3D: genuinely behind the scene. */
    ctx_draw_background (r, r->width, r->height);
    if (r->camera)
      {
        /* begin_LAYER only, never begin_FRAME -- see the note above.
           The renderer's frame bracket presents the hidden shared
           window; the layer bracket is the part that sets up the
           camera (BeginMode3D), which is all an FBO render needs.
           `in_frame' is private bookkeeping nothing reads, and
           begin_layer/end_layer do not consult it. */
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

        /* Persistent positioned textured models (celestial bodies): drawn
         * like the background globe, opaque, at their own positions. */
        if (r->body_models && r->body_models->len)
          {
            static guint dbg_once = 0;
            if (dbg_once++ < 3)
              g_debug ("render: drawing %u body models", r->body_models->len);
            g_autoptr (GrlVector3) naxis = grl_vector3_new (0.0f, 1.0f, 0.0f);
            g_autoptr (GrlVector3) nscl  = grl_vector3_new (1.0f, 1.0f, 1.0f);
            g_autoptr (GrlColor)   nwhite = grl_color_new (255, 255, 255,
                                                           255);
            for (guint i = 0; i < r->body_models->len; i++)
              {
                BodyModel *b = g_ptr_array_index (r->body_models, i);
                if (!b->model) continue;
                g_autoptr (GrlVector3) bp =
                  grl_vector3_new ((gfloat) b->x, (gfloat) b->y,
                                   (gfloat) b->z);
                grl_model_draw_ex (b->model, bp, naxis, 0.0f, nscl, nwhite);
              }
          }
        /* Translucent overlay shells (gnuseye weather: radar/cloud drapes):
         * alpha-blended, depth-TESTED against the opaque globe/bodies (the
         * far limb culls them) but NOT depth-written, so every later pass
         * (polygon fills, coastlines, markers, billboards) depth-tests
         * against the base globe only and always reads on top.  Painter's
         * order, not geometry, provides the layering -- any future slot
         * inserted between here and the markers inherits that contract.
         * Backface culling stays on (near hemisphere only), and the shells
         * follow background_spin_deg so a draped texture stays glued to
         * the globe's geography. */
        if (r->overlay_models && r->overlay_models->len)
          {
            g_autoptr (GrlVector3) opos  = grl_vector3_new (0.0f, 0.0f, 0.0f);
            g_autoptr (GrlVector3) oaxis = grl_vector3_new (0.0f, 1.0f, 0.0f);
            g_autoptr (GrlVector3) oscl  = grl_vector3_new (1.0f, 1.0f, 1.0f);
            g_autoptr (GrlColor)   owhite = grl_color_new (255, 255, 255,
                                                           255);
            BeginBlendMode (BLEND_ALPHA);
            rlDisableDepthMask ();
            for (guint i = 0; i < r->overlay_models->len; i++)
              {
                CmacsOverlayModel *o =
                  g_ptr_array_index (r->overlay_models, i);
                if (!o->model || !o->enabled || o->alpha <= 0.0f) continue;
                /* Always a WHITE OPAQUE tint: the per-channel opacity is
                 * applied by the shell's own shader (an "overlayAlpha"
                 * uniform the gnuseye overlay code sets), NOT by the draw
                 * tint -- a sub-opaque colDiffuse showed sampling
                 * artifacts in the par_shapes pole zones. */
                grl_model_draw_ex (o->model, opos, oaxis,
                                   r->background_spin_deg, oscl, owhite);
              }
            rlEnableDepthMask ();
            EndBlendMode ();
          }
        /* Filled translucent polygon fills (alert zones, choropleth, aurora):
         * drawn after the globe but before coastlines/markers so those
         * overlay them.  Alpha-blended and two-sided (cull disabled) so the
         * translucent drape shows from any viewing angle; positioned in world
         * space at angle 0 to match the coastline/marker overlays. */
        if ((r->static_polygon_models && r->static_polygon_models->len)
            || (r->polygon_models && r->polygon_models->len))
          {
            g_autoptr (GrlVector3) ppos  = grl_vector3_new (0.0f, 0.0f, 0.0f);
            g_autoptr (GrlVector3) paxis = grl_vector3_new (0.0f, 1.0f, 0.0f);
            g_autoptr (GrlVector3) pscl  = grl_vector3_new (1.0f, 1.0f, 1.0f);
            g_autoptr (GrlColor)   pw     = grl_color_new (255, 255, 255, 255);
            BeginBlendMode (BLEND_ALPHA);
            rlDisableBackfaceCulling ();
            for (guint i = 0;
                 r->static_polygon_models && i < r->static_polygon_models->len;
                 i++)
              grl_model_draw_ex (
                g_ptr_array_index (r->static_polygon_models, i),
                ppos, paxis, 0.0f, pscl, pw);
            for (guint i = 0;
                 r->polygon_models && i < r->polygon_models->len; i++)
              grl_model_draw_ex (g_ptr_array_index (r->polygon_models, i),
                                 ppos, paxis, 0.0f, pscl, pw);
            rlEnableBackfaceCulling ();
            EndBlendMode ();
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
        /* Camera-facing billboards.
         *
         * Two behaviours, selected by whether an occluder is set --
         * i.e. whether this scene is a globe.  On a globe (gnuseye)
         * flags appear only once zoomed in and scale with the camera's
         * height above the surface, which is what keeps a flag a
         * roughly constant size on screen.  Without one (a graph, whose
         * nodes are icons at fixed world positions) neither rule makes
         * sense: the zoom gate keys on distance from the ORIGIN, so a
         * scene laid out past radius 13 would simply never draw an
         * icon, and the altitude scaling has no surface to be above. */
        if (r->billboards && r->billboards->len > 0)
          {
            Camera3D bcam = ctx_raylib_camera (r);
            double cdist = sqrt (bcam.position.x*bcam.position.x
                                 + bcam.position.y*bcam.position.y
                                 + bcam.position.z*bcam.position.z);
            gboolean globe = (r->occluder_radius > 0.0);
            if (!globe || cdist < 13.0)
              {
                Color bw = (Color){ 255, 255, 255, 255 };
                CmacsBillboardOrder *order =
                  g_new (CmacsBillboardOrder, r->billboards->len);
                guint n_norm = 0, n_glow = 0, oi;
                (void) bw;

                /* Split the layers and depth-sort the normal one.
                 * Alpha-blended quads MUST draw back-to-front: a quad's
                 * translucent texels still write depth, so drawn in
                 * insertion order a near quad's soft edge clips every
                 * quad behind it into a rectangle -- an artefact that
                 * only appears once the camera orbits and two nodes
                 * overlap, which is exactly when you are looking. */
                for (guint i = 0; i < r->billboards->len; i++)
                  {
                    CmacsBillboard *bb =
                      &g_array_index (r->billboards, CmacsBillboard, i);
                    float dx, dy, dz;

                    if (!bb->tex) continue;
                    /* Skip flags on the far side of the globe. */
                    if (!ctx_point_near_side (r, bb->x, bb->y, bb->z))
                      continue;
                    if (bb->layer != 0) { n_glow++; continue; }
                    dx = bb->x - bcam.position.x;
                    dy = bb->y - bcam.position.y;
                    dz = bb->z - bcam.position.z;
                    order[n_norm].key = dx * dx + dy * dy + dz * dz;
                    order[n_norm].idx = i;
                    n_norm++;
                  }
                qsort (order, n_norm, sizeof *order,
                       cmacs_billboard_order_cmp);

                for (oi = 0; oi < n_norm; oi++)
                  {
                    CmacsBillboard *bb =
                      &g_array_index (r->billboards, CmacsBillboard,
                                      order[oi].idx);
                    Texture2D *t = grl_texture_get_handle (bb->tex);
                    if (t && t->id)
                      {
                        /* On a globe, scale to the zoom so the flag
                         * keeps a roughly constant on-screen size (world
                         * size grows with distance from the camera to the
                         * near surface).  Off a globe, the size given is
                         * the size meant. */
                        float esize = bb->size;
                        if (globe)
                          {
                            double near = cdist - r->occluder_radius;
                            if (near < 0.6) near = 0.6;
                            esize = bb->size * (float) near;
                          }
                        Color tint =
                          bb->rgba
                          ? (Color){ (unsigned char) ((bb->rgba >> 24) & 0xFF),
                                     (unsigned char) ((bb->rgba >> 16) & 0xFF),
                                     (unsigned char) ((bb->rgba >>  8) & 0xFF),
                                     (unsigned char) ( bb->rgba        & 0xFF) }
                          : bw;
                        DrawBillboard (bcam, *t,
                                       (Vector3){ bb->x, bb->y, bb->z },
                                       esize, tint);
                      }
                  }
                g_free (order);

                /* The glow layer: additive, depth mask off, unsorted --
                 * addition commutes, so order cannot matter, and a glow
                 * must never punch a depth hole in front of another.
                 * Depth TESTING stays on: a glow behind real geometry
                 * is hidden, which is what anchors it to its node.
                 * Same bracket discipline as the particle pass: flush
                 * the batch before touching the depth mask, because
                 * rlgl applies mask changes immediately while quads sit
                 * batched. */
                if (n_glow > 0)
                  {
                    rlDrawRenderBatchActive ();
                    rlDisableDepthMask ();
                    BeginBlendMode (BLEND_ADDITIVE);
                    for (guint i = 0; i < r->billboards->len; i++)
                      {
                        CmacsBillboard *bb =
                          &g_array_index (r->billboards, CmacsBillboard, i);
                        Texture2D *t;

                        if (!bb->tex || bb->layer != 1) continue;
                        if (!ctx_point_near_side (r, bb->x, bb->y, bb->z))
                          continue;
                        t = grl_texture_get_handle (bb->tex);
                        if (t && t->id)
                          {
                            Color tint =
                              bb->rgba
                              ? (Color){ (unsigned char) ((bb->rgba >> 24) & 0xFF),
                                         (unsigned char) ((bb->rgba >> 16) & 0xFF),
                                         (unsigned char) ((bb->rgba >>  8) & 0xFF),
                                         (unsigned char) ( bb->rgba        & 0xFF) }
                              : bw;
                            DrawBillboard (bcam, *t,
                                           (Vector3){ bb->x, bb->y, bb->z },
                                           bb->size, tint);
                          }
                      }
                    EndBlendMode ();
                    rlDrawRenderBatchActive ();
                    rlEnableDepthMask ();
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
            float mdeg = 0.0f, moff[3] = { 0.0f, 0.0f, 0.0f };
            /* Rotate about the part's own (scaled) centre so it spins in
             * place rather than orbiting the model origin. */
            g_autoptr (GrlVector3) maxis =
              cmacs_editor_rotation_for_draw (em->rx, em->ry, em->rz,
                                              em->cx * em->sx, em->cy * em->sy,
                                              em->cz * em->sz, &mdeg, moff);
            g_autoptr (GrlVector3) mpos  = grl_vector3_new (em->x + moff[0],
                                                            em->y + moff[1],
                                                            em->z + moff[2]);
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
                                           mdeg, mscl, mtint);
                else
                  {
                    grl_model_draw_ex (em->model, mpos, maxis,
                                       mdeg, mscl, mtint);
                    /* Shaded-with-edges: overlay the wireframe in a dark
                     * tint, scaled out by a hair so it sits just proud of
                     * the surface (avoids z-fighting shimmer). */
                    if (r->edges)
                      {
                        g_autoptr (GrlVector3) escl =
                          grl_vector3_new (em->sx * 1.0025f,
                                           em->sy * 1.0025f,
                                           em->sz * 1.0025f);
                        g_autoptr (GrlColor) ecol =
                          grl_color_new (30, 34, 44, 255);
                        grl_model_draw_wires_ex (em->model, mpos, maxis,
                                                 mdeg, escl, ecol);
                      }
                  }
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
            && (guint) r->selected < r->nodes->len
            && r->selection_style != CMACS_LIBREGNUM_SELECTION_NONE)
          {
            CmacsNode *n = &g_array_index (r->nodes, CmacsNode,
                                           (guint) r->selected);
            Vector3 c = (Vector3){ n->x, n->y, n->z };

            if (r->selection_style == CMACS_LIBREGNUM_SELECTION_HALO)
              {
                /* A shell around the node.  Wireframe rather than solid
                   so it reads as a marker and not as another node, and
                   because a translucent sphere samples badly at the UV
                   poles in this renderer. */
                float rad = fmaxf (n->hw, fmaxf (n->hh, n->hd)) * 2.1f + 0.18f;
                DrawSphereWires (c, rad, 8, 12,
                                 (Color){ 255, 235, 120, 170 });
              }
            else
              DrawCubeWires (c, n->hw * 2 + 0.35f, n->hh * 2 + 0.35f,
                             n->hd * 2 + 0.35f, (Color){ 255, 235, 120, 255 });
          }
#ifdef LRG_BUILD_EDITOR
        /* Transform gizmo handles over the selection (translate/rotate/scale). */
        cmacs_editor_draw_gizmo (r);
#endif
        /* Particles last inside the 3D layer: additive blending wants
         * the solid geometry already in the depth buffer. */
        ctx_particles_step_and_draw (r);

        lrg_renderer_end_layer (r->renderer);
      }

    /* Screen-space label pass, INSIDE the FBO bracket.  Drawing labels
     * here rather than in the pgtk cairo overlay is what makes them
     * appear under `emacs --lrg' as well: both backends funnel through
     * this function (DST==NULL for the lrg FBO-only path), so one code
     * path serves both -- and snapshot_png can see them, which is what
     * makes them testable at all. */
    if (r->inscene_labels)
      ctx_draw_node_labels (r);

    /* Flush unconditionally.  EndMode3D (inside lrg_renderer_end_layer)
     * submits the 3D batch, but anything drawn AFTER it opens a fresh
     * batch that EndTextureMode would only submit *after* the readback
     * below.  Omit this and labels render fine under --lrg (which never
     * reads back) and are invisible under pgtk.  Same asymmetry the
     * chart-mode path documents. */
    rlDrawRenderBatchActive ();

    /* Read the FBO colour attachment back while it is still bound.
     * GL_BGRA + GL_UNSIGNED_BYTE matches cairo's ARGB32 byte order on
     * little-endian, so the driver writes straight into DST with no
     * channel-swap loop and no per-frame allocation.  Row stride is
     * width*4, a multiple of the default GL_PACK_ALIGNMENT (4). */
    if (dst)
      glReadPixels (0, 0, r->width, r->height,
                    GL_BGRA, GL_UNSIGNED_BYTE, dst);
  }
  EndTextureMode ();

  return TRUE;
}

/* Bounding box of everything that is not the background colour, in
   DISPLAYED orientation (y grows downward, the same convention
   `project' and `label_at' report in).  Renders a frame synchronously,
   like snapshot_png, so it works headless.

   This exists for automated render verification.  A snapshot only tells
   you that pixels changed; it cannot tell you they changed in the right
   place -- and the framebuffer being bottom-up while the blit flips it
   makes "in the right place" the specific thing worth asserting about
   any 2D overlay pass.  Returns FALSE if nothing was drawn. */
gboolean
cmacs_libregnum_render_ctx_mean_color (CmacsLibregnumRenderCtx *r,
                                       int *out_r, int *out_g, int *out_b)
{
  unsigned char *buf;
  int w, h;
  gsize i, n;
  guint64 sr = 0, sg = 0, sb = 0;

  if (!r) return FALSE;
  w = r->width;
  h = r->height;
  if (w <= 0 || h <= 0) return FALSE;

  buf = g_malloc0 ((gsize) w * h * 4);
  if (!cmacs_libregnum_render_ctx_render_to_bgra (r, buf, w, h))
    {
      g_free (buf);
      return FALSE;
    }

  /* render_to_bgra hands back BGRA, so index accordingly -- getting
     this wrong here would hide exactly the bug this exists to find. */
  n = (gsize) w * (gsize) h;
  for (i = 0; i < n; i++)
    {
      sb += buf[i * 4 + 0];
      sg += buf[i * 4 + 1];
      sr += buf[i * 4 + 2];
    }
  g_free (buf);

  if (out_r) *out_r = (int) (sr / n);
  if (out_g) *out_g = (int) (sg / n);
  if (out_b) *out_b = (int) (sb / n);
  return TRUE;
}

gboolean
cmacs_libregnum_render_ctx_ink_bbox (CmacsLibregnumRenderCtx *r,
                                     int *minx, int *miny,
                                     int *maxx, int *maxy)
{
  unsigned char *buf;
  int w, h, x, y;
  int lo_x, lo_y, hi_x, hi_y;
  unsigned char br, bg, bb;
  gboolean any = FALSE;

  if (!r) return FALSE;
  w = r->width;
  h = r->height;
  if (w <= 0 || h <= 0) return FALSE;

  buf = g_malloc0 ((gsize) w * h * 4);
  if (!cmacs_libregnum_render_ctx_render_to_bgra (r, buf, w, h))
    {
      g_free (buf);
      return FALSE;
    }

  /* The clear colour is the background; anything else is ink.  Sample
     the corner rather than trusting a stored value, so this stays
     correct for every render mode. */
  bb = buf[0]; bg = buf[1]; br = buf[2];

  lo_x = w; lo_y = h; hi_x = -1; hi_y = -1;
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++)
      {
        const unsigned char *p = buf + ((gsize) y * w + x) * 4;
        /* Small tolerance: the scene is lit, so the background can
           carry a little gradient noise. */
        if (abs ((int) p[0] - (int) bb) <= 6
            && abs ((int) p[1] - (int) bg) <= 6
            && abs ((int) p[2] - (int) br) <= 6)
          continue;
        {
          /* glReadPixels' origin is lower-left; report in the flipped,
             displayed orientation so callers can compare against
             `project'. */
          int dy = h - 1 - y;
          if (x < lo_x)  lo_x = x;
          if (x > hi_x)  hi_x = x;
          if (dy < lo_y) lo_y = dy;
          if (dy > hi_y) hi_y = dy;
          any = TRUE;
        }
      }

  g_free (buf);
  if (!any) return FALSE;
  if (minx) *minx = lo_x;
  if (miny) *miny = lo_y;
  if (maxx) *maxx = hi_x;
  if (maxy) *maxy = hi_y;
  return TRUE;
}

/* Render the scene INTO the FBO without reading it back (the lrg overlay
   then draws fbo.texture directly).  Called from inside the lrg present, so
   it shares the GL context with lrg's 2D text drawing: flush lrg's pending
   batch first, and after EndTextureMode turn depth-testing off so the lrg
   2D texture blit that follows is not depth-culled.  */
gboolean
cmacs_libregnum_render_ctx_render_into_fbo (CmacsLibregnumRenderCtx *r)
{
  gboolean ok;

  if (!r) return FALSE;
  rlDrawRenderBatchActive ();
  ok = cmacs_libregnum_render_ctx_render_to_bgra (r, NULL, r->width, r->height);
  rlDisableDepthTest ();
  return ok;
}

/* A non-owning GrlTexture wrapping the FBO's colour attachment, for the lrg
   overlay to blit.  Cached on the ctx; invalidated on resize/free.  Returned
   as gpointer so render.h stays raylib/graylib-free.  */
gpointer
cmacs_libregnum_render_ctx_get_fbo_texture (CmacsLibregnumRenderCtx *r)
{
  if (!r || !r->fbo_valid) return NULL;
  if (r->fbo_grl_texture == NULL)
    r->fbo_grl_texture = grl_texture_new_from_handle (&r->fbo.texture);
  return r->fbo_grl_texture;
}

#include <math.h>

/* Keep a camera position outside the occluding sphere (the gnuseye globe):
 * push it radially out to a floor just above the surface so no camera motion
 * (zoom, orbit around an off-centre target, pan) can pass through the globe.
 * No-op when no occluder is set (editor scenes, the flat map). */
#define CTX_OCCLUDER_FLOOR  1.002   /* min camera radius, x surface radius */
#define CTX_OCCLUDER_CEIL   1500.0  /* max camera radius, x surface radius
                                     * (~9550 units: frames the linearly-true
                                     * solar system, Neptune ~8700 out; the
                                     * far cull plane is raised to 20000 at
                                     * window acquire) */

static void
ctx_clamp_above_occluder (CmacsLibregnumRenderCtx *r,
                          double *x, double *y, double *z)
{
  if (!r || r->occluder_radius <= 0.0) return;
  double mind = r->occluder_radius * CTX_OCCLUDER_FLOOR;
  double len = sqrt ((*x) * (*x) + (*y) * (*y) + (*z) * (*z));
  if (len < 1e-9) { *x = 0.0; *y = mind; *z = 0.0; return; }
  if (len < mind)
    { double k = mind / len; *x *= k; *y *= k; *z *= k; }
}

void
cmacs_libregnum_render_ctx_orbit_camera (CmacsLibregnumRenderCtx *r,
                                         double dx_px, double dy_px)
{
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
#ifdef LRG_BUILD_EDITOR
  if (r->camera_lookthrough) return; /* suppressed during look-through */
#endif
  /* A flat view stays flat: a scene showing a planar layout head-on has
     nothing to orbit around, and tumbling it would only reveal that
     everything is coplanar.  Pan and zoom stay live. */
  if (r->orbit_locked) return;
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
  /* Orbiting an off-centre target (a selected entity) can swing the camera
   * into the globe; keep it above the surface. */
  double wx = tgt->x + nx, wy = tgt->y + ny, wz = tgt->z + nz;
  ctx_clamp_above_occluder (r, &wx, &wy, &wz);
  lrg_camera3d_set_position_xyz (c3, (float) wx, (float) wy, (float) wz);
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

  if (r->focus_min_dist > 0.0)
    {
      /* Orbiting an off-origin focus (a selected celestial body): zoom is
       * proportional to the distance to the TARGET, asymptotic to the
       * body's own floor -- you can get ever closer to the planet, never
       * inside it, and never shoot past it. */
      double ox = pos->x - tgt->x, oy = pos->y - tgt->y, oz = pos->z - tgt->z;
      double vlen = sqrt (ox*ox + oy*oy + oz*oz);
      if (vlen < 1e-9) return;
      double above = vlen - r->focus_min_dist;
      if (above < 1e-3) above = 1e-3;
      double nabove = above * pow (0.9, wheel_dy);
      if (nabove < 1e-3) nabove = 1e-3;
      double k = (r->focus_min_dist + nabove) / vlen;
      double wx = tgt->x + ox * k, wy = tgt->y + oy * k, wz = tgt->z + oz * k;
      /* Stay outside the Earth globe and inside the world ceiling. */
      ctx_clamp_above_occluder (r, &wx, &wy, &wz);
      if (r->occluder_radius > 0.0)
        {
          double maxd = r->occluder_radius * CTX_OCCLUDER_CEIL;
          double wlen = sqrt (wx*wx + wy*wy + wz*wz);
          if (wlen > maxd && wlen > 1e-9)
            { double s = maxd / wlen; wx *= s; wy *= s; wz *= s; }
        }
      lrg_camera3d_set_position_xyz (c3, (float) wx, (float) wy, (float) wz);
      return;
    }

  if (r->occluder_radius > 0.0)
    {
      /* Globe zoom: scale the camera's ALTITUDE above the occluder surface,
       * not its distance to the target.  Each wheel tick consumes a fixed
       * fraction of the remaining altitude, so steps shrink as you get
       * closer (ever-finer zoom near the surface) and the surface is an
       * asymptote -- with a hard radial floor so the camera can never pass
       * through the globe, and a ceiling so it cannot get lost in space. */
      double vx = tgt->x - pos->x, vy = tgt->y - pos->y, vz = tgt->z - pos->z;
      double vlen = sqrt (vx*vx + vy*vy + vz*vz);
      if (vlen < 1e-9) return;
      vx /= vlen; vy /= vlen; vz /= vlen;
      double mind = r->occluder_radius * CTX_OCCLUDER_FLOOR;
      double maxd = r->occluder_radius * CTX_OCCLUDER_CEIL;
      double clen = sqrt (pos->x * pos->x + pos->y * pos->y
                          + pos->z * pos->z);
      double above = clen - mind;
      if (above < 5e-4) above = 5e-4;
      double nabove = above * pow (0.9, wheel_dy);
      if (nabove < 5e-4) nabove = 5e-4;
      if (nabove > maxd - mind) nabove = maxd - mind;
      double step = above - nabove;            /* + = toward the target */
      double wx = pos->x + vx * step;
      double wy = pos->y + vy * step;
      double wz = pos->z + vz * step;
      ctx_clamp_above_occluder (r, &wx, &wy, &wz);
      /* Ceiling: zooming out stops before the globe becomes a speck. */
      double wlen = sqrt (wx*wx + wy*wy + wz*wz);
      if (wlen > maxd && wlen > 1e-9)
        { double k = maxd / wlen; wx *= k; wy *= k; wz *= k; }
      lrg_camera3d_set_position_xyz (c3, (float) wx, (float) wy, (float) wz);
      return;
    }

  /* No occluder (editor scenes, the flat map): scale the distance to the
   * target -- asymptotic toward it, so it cannot invert through. */
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
  /* Panning translates the camera in the view plane, which on a sphere can
   * dip it below the surface near the limb; keep it above. */
  double wx = pos->x + mx, wy = pos->y + my, wz = pos->z + mz;
  ctx_clamp_above_occluder (r, &wx, &wy, &wz);
  lrg_camera3d_set_position_xyz (c3, (float) wx, (float) wy, (float) wz);
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
   * order, so the buffer feeds cairo directly.  glReadPixels' origin is
   * the lower-left corner: the GUI paint hook flips with a cairo matrix,
   * but a PNG written straight from this buffer is upside down -- which
   * silently inverted every snapshot-based orientation check.  Flip the
   * rows so snapshots match what the user sees. */
  {
    gsize stride = (gsize) r->width * 4;
    g_autofree unsigned char *tmp = g_malloc (stride);
    for (int y = 0; y < r->height / 2; y++)
      {
        unsigned char *a = buf + (gsize) y * stride;
        unsigned char *b = buf + (gsize) (r->height - 1 - y) * stride;
        memcpy (tmp, a, stride);
        memcpy (a, b, stride);
        memcpy (b, tmp, stride);
      }
  }
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
  /* faceNormals=1: per-triangle (flat) normal from the world-position
   * gradient, so prismatic faces shade uniformly regardless of the mesh's
   * (possibly averaged) vertex normals -- the CAD look.  =0: interpolated
   * vertex normals (smooth) for organic/game meshes. */
  "uniform int faceNormals;\n"
  "void main() {\n"
  "    vec4 texelColor = texture(texture0, fragTexCoord);\n"
  "    vec3 base   = (texelColor*colDiffuse*fragColor).rgb;\n"
  "    vec3 normal = (faceNormals == 1)\n"
  "        ? normalize(cross(dFdx(fragPosition), dFdy(fragPosition)))\n"
  "        : normalize(fragNormal);\n"
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

  /* Flat (face) normals in the CAD headlight mode -- see the shader. */
  loc = GetShaderLocation (*sh, "faceNormals");
  if (loc >= 0)
    {
      int fn = r->headlight ? 1 : 0;
      SetShaderValue (*sh, loc, &fn, SHADER_UNIFORM_INT);
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

  /* Headlight rig: synthesise a key + fill light from the camera frame so a
   * model-only scene (no LIGHT nodes) is lit by surface orientation rather
   * than rendering flat.  Point lights with no attenuation, anchored around
   * the look-at target; intensities are kept under 1.0 so a mid-tone base
   * stays inside [0,1] (no highlight clip -> no white wash-out). */
  if (r->headlight)
    {
      float fwd[3] = { cam.target.x - cam.position.x,
                       cam.target.y - cam.position.y,
                       cam.target.z - cam.position.z };
      float fl = sqrtf (fwd[0]*fwd[0] + fwd[1]*fwd[1] + fwd[2]*fwd[2]);
      float dist = (fl > 1e-4f) ? fl : 1.0f;
      float upv[3] = { cam.up.x, cam.up.y, cam.up.z };
      float rgt[3], rup[3], rl;
      int k;

      if (fl > 1e-4f) { fwd[0]/=fl; fwd[1]/=fl; fwd[2]/=fl; }
      rgt[0] = fwd[1]*upv[2] - fwd[2]*upv[1];
      rgt[1] = fwd[2]*upv[0] - fwd[0]*upv[2];
      rgt[2] = fwd[0]*upv[1] - fwd[1]*upv[0];
      rl = sqrtf (rgt[0]*rgt[0] + rgt[1]*rgt[1] + rgt[2]*rgt[2]);
      if (rl > 1e-4f) { rgt[0]/=rl; rgt[1]/=rl; rgt[2]/=rl; }
      rup[0] = rgt[1]*fwd[2] - rgt[2]*fwd[1];
      rup[1] = rgt[2]*fwd[0] - rgt[0]*fwd[2];
      rup[2] = rgt[0]*fwd[1] - rgt[1]*fwd[0];

      (void) dist;
      for (k = 0; k < 2 && light_count < 4; k++)
        {
          /* DIRECTIONAL lights (constant L across the surface) so flat faces
           * shade uniformly -- a point light here gives a distracting
           * distance gradient across large faces.  k=0 key (upper-right,
           * toward camera); k=1 fill (left, softer).  For directional, the
           * shader uses L = normalize(position - target); we leave target at
           * the origin and set position to the light DIRECTION. */
          float ox    = (k == 0) ?  0.55f : -0.65f;
          float oy    = (k == 0) ?  0.75f :  0.15f;
          float oz    = (k == 0) ? -0.45f : -0.30f;
          float inten = (k == 0) ?  0.80f :  0.38f;
          float ld[3] = { rgt[0]*ox + rup[0]*oy + fwd[0]*oz,
                          rgt[1]*ox + rup[1]*oy + fwd[1]*oz,
                          rgt[2]*ox + rup[2]*oy + fwd[2]*oz };
          float lt[3] = { 0.0f, 0.0f, 0.0f };
          float lc[4] = { inten, inten, inten * 1.04f, 1.0f };
          int en = 1, type = 0;   /* LIGHT_DIRECTIONAL */

          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].enabled", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0) SetShaderValue (*sh, loc, &en, SHADER_UNIFORM_INT);
          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].type", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0) SetShaderValue (*sh, loc, &type, SHADER_UNIFORM_INT);
          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].position", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0) SetShaderValue (*sh, loc, ld, SHADER_UNIFORM_VEC3);
          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].target", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0) SetShaderValue (*sh, loc, lt, SHADER_UNIFORM_VEC3);
          g_snprintf (name_buf, sizeof (name_buf),
                      "lights[%d].color", light_count);
          loc = GetShaderLocation (*sh, name_buf);
          if (loc >= 0) SetShaderValue (*sh, loc, lc, SHADER_UNIFORM_VEC4);
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
    case LRG_NODE_VISUAL_CAD_PART:        cr = 150; cg = 180; cb = 255; break;
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
          em.cx = 0.0f; em.cy = 0.0f; em.cz = 0.0f;
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
  else if (kind == LRG_NODE_VISUAL_CAD_PART)
    {
#ifdef HAVE_CMACS_CAD
      /* CMACS: parametric CAD part -- evaluate + tessellate through the
       * libregnum CAD manager (cached by path + "cad:" param overrides)
       * and draw every 16-bit-safe chunk as a model at this node's TRS. */
      const char *asset = lrg_node_visual_get_asset (vis);
      LrgCadBakeResult *bake = NULL;
      if (asset && asset[0])
        {
          LrgCadManager *mgr = lrg_cad_manager_get_default ();
          GHashTable *overrides = lrg_cad_manager_overrides_for_node (node);
          gdouble defl = lrg_node_visual_get_param_double (vis,
                                                           "cad:deflection",
                                                           0.0);
          GError *cad_error = NULL;
          bake = lrg_cad_manager_bake (mgr, asset, overrides, defl, NULL,
                                       &cad_error);
          if (overrides)
            g_hash_table_unref (overrides);
          if (cad_error)
            {
              g_message ("cmacs-cad: bake of %s failed: %s", asset,
                         cad_error->message);
              g_clear_error (&cad_error);
            }
        }
      if (bake)
        {
          GPtrArray *models = lrg_cad_bake_result_get_models (bake);
          CadSolid  *solid  = lrg_cad_bake_result_get_solid (bake);
          gdouble mn[3], mx[3];
          guint ci;

          cad_solid_get_bbox (solid, &mn[0], &mn[1], &mn[2],
                              &mx[0], &mx[1], &mx[2]);
          hw = (float) (mx[0] - mn[0]) * 0.5f;
          hh = (float) (mx[1] - mn[1]) * 0.5f;
          hd = (float) (mx[2] - mn[2]) * 0.5f;
          if (hw < 0.05f) hw = 0.5f;
          if (hh < 0.05f) hh = 0.5f;
          if (hd < 0.05f) hd = 0.5f;

          for (ci = 0; models && ci < models->len; ci++)
            {
              CmacsEditorModel em;
              em.model = g_object_ref (g_ptr_array_index (models, ci));
              em.texture = NULL;
              em.flat = FALSE;
              em.tiles = NULL;
              em.tile_rgb = NULL; em.tile_models = NULL;
              em.tile_textures = NULL;
              em.x = x; em.y = y; em.z = z;
              em.rx = rrx; em.ry = rry; em.rz = rrz;
              em.sx = ssx; em.sy = ssy; em.sz = ssz;
              /* Pivot = the solid's model-space AABB centre, so node
               * rotation spins the part in place rather than orbiting the
               * (often far-off) model origin. */
              em.cx = (float) (mn[0] + mx[0]) * 0.5f;
              em.cy = (float) (mn[1] + mx[1]) * 0.5f;
              em.cz = (float) (mn[2] + mx[2]) * 0.5f;
              /* Mid-tone steel: a near-white base clips to white once lit
               * (the wash-out); this keeps shading inside [0,1]. */
              em.cr = 150; em.cg = 165; em.cb = 200;
              em.node_id = (gint) r->nodes->len; /* id add_node assigns */
              if (r->editor_models)
                g_array_append_val (r->editor_models, em);
              else
                g_object_unref (em.model);
            }
          hw *= fabsf (ssx); hh *= fabsf (ssy); hd *= fabsf (ssz);
          /* Refit the axis-aligned selection / pick box to the ROTATED
           * extents (|R| * half-extents), so it bounds the part after a
           * turn instead of staying sized to the unrotated geometry.
           * Identity rotation leaves it unchanged. */
          {
            g_autoptr (GrlMatrix) rb = grl_matrix_new_rotate_xyz (rrx, rry,
                                                                  rrz);
            if (rb)
              {
                float ehw = fabsf (rb->m0) * hw + fabsf (rb->m4) * hh
                            + fabsf (rb->m8) * hd;
                float ehh = fabsf (rb->m1) * hw + fabsf (rb->m5) * hh
                            + fabsf (rb->m9) * hd;
                float ehd = fabsf (rb->m2) * hw + fabsf (rb->m6) * hh
                            + fabsf (rb->m10) * hd;
                hw = ehw; hh = ehh; hd = ehd;
              }
          }
          /* Parts are modeled in their own coordinates, usually NOT
           * centered on the node origin: record the solid's AABB center
           * as the node-entry center so the selection box, pick, focus
           * and label track the geometry.  Rotation pivots about this
           * centre (see cmacs_editor_rotation_for_draw), so the centre
           * stays put and the box above bounds the turned part. */
          x += (float) (mn[0] + mx[0]) * 0.5f * ssx;
          y += (float) (mn[1] + mx[1]) * 0.5f * ssy;
          z += (float) (mn[2] + mx[2]) * 0.5f * ssz;
        }
      else
        /* No asset / failed bake: a blue placeholder cube. */
        shape = LRG_SHAPE (lrg_cube3d_new_at (x, y, z, 1.0f, 1.0f, 1.0f));
#else
      /* CAD support compiled out: placeholder so levels stay loadable. */
      shape = LRG_SHAPE (lrg_cube3d_new_at (x, y, z, 1.0f, 1.0f, 1.0f));
#endif /* HAVE_CMACS_CAD */
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
          em.cx = 0.0f; em.cy = 0.0f; em.cz = 0.0f;
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
          em.cx = 0.0f; em.cy = 0.0f; em.cz = 0.0f;
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

/* Undoable visual-param set: routes through the editor's command stack so
 * it participates in undo/redo.  MERGE folds a continuing slider drag onto
 * the previous command.  Returns FALSE if there is no such node/editor. */
gboolean
cmacs_libregnum_render_ctx_editor_set_visual_param_undoable
                                          (CmacsLibregnumRenderCtx *r,
                                           gint id, const char *name,
                                           double value, gboolean merge)
{
  LrgNode *n = cmacs_editor_node_for_id (r, id);
  if (!n || !name || !r->editor) return FALSE;
  lrg_editor_set_visual_param (r->editor, n, name, value, merge);
  cmacs_editor_rebuild (r);
  return TRUE;
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

/* Synthesise a camera-anchored key+fill rig each frame (CAD model viewer
 * lighting); requires shading to be on to have any effect. */
void
cmacs_libregnum_render_ctx_editor_set_headlight (CmacsLibregnumRenderCtx *r,
                                                 gboolean on)
{
  if (!r) return;
  r->headlight = on;
}

/* Overlay a dark wireframe on shaded models (shaded-with-edges). */
void
cmacs_libregnum_render_ctx_editor_set_edges (CmacsLibregnumRenderCtx *r,
                                             gboolean on)
{
  if (!r) return;
  r->edges = on;
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
void cmacs_libregnum_render_ctx_editor_set_headlight (CmacsLibregnumRenderCtx *r,
         gboolean on) { (void) r; (void) on; }
void cmacs_libregnum_render_ctx_editor_set_edges (CmacsLibregnumRenderCtx *r,
         gboolean on) { (void) r; (void) on; }
gboolean cmacs_libregnum_render_ctx_editor_look_through (CmacsLibregnumRenderCtx *r,
         gint id) { (void) r; (void) id; return FALSE; }
void cmacs_libregnum_render_ctx_editor_look_through_off (CmacsLibregnumRenderCtx *r)
{ (void) r; }
gint cmacs_libregnum_render_ctx_editor_look_through_p (CmacsLibregnumRenderCtx *r)
{ (void) r; return -1; }
double cmacs_libregnum_render_ctx_editor_get_visual_param (CmacsLibregnumRenderCtx *r,
         gint id, const char *name, double def)
{ (void) r; (void) id; (void) name; return def; }
gboolean cmacs_libregnum_render_ctx_editor_set_visual_param_undoable
         (CmacsLibregnumRenderCtx *r, gint id, const char *name,
          double value, gboolean merge)
{ (void) r; (void) id; (void) name; (void) value; (void) merge;
  return FALSE; }

#endif /* LRG_BUILD_EDITOR */

#endif /* HAVE_CMACS_LIBREGNUM */


/* ── CMACS CAD: public hooks for the Lisp layer ───────────────────────── */

void
cmacs_libregnum_render_ctx_editor_refresh (CmacsLibregnumRenderCtx *r)
{
  if (r && r->editor)
    cmacs_editor_rebuild (r);
}

#ifdef HAVE_CMACS_CAD
void
cmacs_libregnum_render_cad_invalidate (const char *path)
{
  lrg_cad_manager_invalidate (lrg_cad_manager_get_default (), path);
}

gboolean
cmacs_libregnum_render_cad_set_source (const char *path,
                                       const char *source,
                                       GError **error)
{
  return lrg_cad_manager_set_source (lrg_cad_manager_get_default (),
                                     path, source, error);
}
#endif /* HAVE_CMACS_CAD */
