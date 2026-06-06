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

#include <libregnum.h>
#include <graylib.h>
#include <raylib.h>
#include <glib.h>
#include <string.h>
#include <math.h>

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
  if (shared_refs++ > 0) return TRUE;

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
  if (shared_refs == 0) return;
  if (--shared_refs > 0) return;
  if (shared_engine)
    {
      lrg_engine_shutdown (shared_engine);
      shared_engine = NULL;
    }
  g_clear_object (&shared_window);
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
} CmacsNode;

static void
cmacs_node_clear (gpointer p)
{
  CmacsNode *n = p;
  g_clear_pointer (&n->path, g_free);
  g_clear_pointer (&n->name, g_free);
}

/* ── Per-view render context (opaque to view.c) ────────────────── */

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
  LrgGameTemplate  *game;          /* borrowed from loaded_game */
  LrgGameHost      *game_host;     /* owned (CmacsFboGameHost) */
  LrgInputSoftware *game_input;    /* owned; registered with input manager */
};

CmacsLibregnumRenderCtx *
cmacs_libregnum_render_ctx_new (int w, int h)
{
  if (!shared_window) return NULL;
  CmacsLibregnumRenderCtx *r = g_new0 (CmacsLibregnumRenderCtx, 1);
  r->width  = w;
  r->height = h;
  r->selected = -1;
  r->renderer  = lrg_renderer_new (LRG_WINDOW (shared_window));
  r->drawables = g_ptr_array_new_with_free_func (g_object_unref);
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
  if (r->fbo_valid) UnloadRenderTexture (r->fbo);
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

/* Build a raylib Camera3D snapshot from the live LrgCamera3D. */
static Camera3D
ctx_raylib_camera (CmacsLibregnumRenderCtx *r)
{
  Camera3D c = { 0 };
  c.up = (Vector3){ 0.0f, 1.0f, 0.0f };
  c.fovy = 60.0f;
  c.projection = CAMERA_PERSPECTIVE;
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
  return cmacs_libregnum_render_ctx_project (r, n->x, n->y + n->hh + 0.25f,
                                             n->z, vw, vh, sx, sy);
}

/* Aim the camera at node ID: target = node center, position backed off
 * along the current view direction by a distance scaled to node size.
 * Animated by step_focus() over subsequent frames. */
void
cmacs_libregnum_render_ctx_focus_node (CmacsLibregnumRenderCtx *r, gint id)
{
  if (!r || !r->nodes || id < 0 || (guint) id >= r->nodes->len) return;
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
        for (guint i = 0; r->drawables && i < r->drawables->len; i++)
          {
            gpointer d = g_ptr_array_index (r->drawables, i);
            if (LRG_IS_DRAWABLE (d))
              lrg_drawable_draw (LRG_DRAWABLE (d), 0.0f);
          }
        /* Selection highlight: a bright wireframe box around the
         * selected node, drawn in the same 3D layer so it depth-sorts
         * against the scene. */
        if (r->selected >= 0 && r->nodes
            && (guint) r->selected < r->nodes->len)
          {
            CmacsNode *n = &g_array_index (r->nodes, CmacsNode,
                                           (guint) r->selected);
            Vector3 c = (Vector3){ n->x, n->y, n->z };
            DrawCubeWires (c, n->hw * 2 + 0.35f, n->hh * 2 + 0.35f,
                           n->hd * 2 + 0.35f, (Color){ 255, 235, 120, 255 });
          }
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

#endif /* HAVE_CMACS_LIBREGNUM */
