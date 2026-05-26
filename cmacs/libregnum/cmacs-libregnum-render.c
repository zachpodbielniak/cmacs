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
};

CmacsLibregnumRenderCtx *
cmacs_libregnum_render_ctx_new (int w, int h)
{
  if (!shared_window) return NULL;
  CmacsLibregnumRenderCtx *r = g_new0 (CmacsLibregnumRenderCtx, 1);
  r->width  = w;
  r->height = h;
  r->renderer  = lrg_renderer_new (LRG_WINDOW (shared_window));
  r->drawables = g_ptr_array_new_with_free_func (g_object_unref);

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
  if (r->fbo_valid) UnloadRenderTexture (r->fbo);
  g_clear_object (&r->camera);
  if (r->drawables) g_ptr_array_unref (r->drawables);
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

/* Render one frame into the FBO and copy the result into DST.
 * DST is BGRA (cairo ARGB32 in memory) pre-allocated to w*h*4. */
gboolean
cmacs_libregnum_render_ctx_render_to_bgra (CmacsLibregnumRenderCtx *r,
                                           unsigned char *dst,
                                           int dst_w, int dst_h)
{
  if (!r || !r->fbo_valid || !dst) return FALSE;
  if (dst_w != r->width || dst_h != r->height) return FALSE;

  lrg_window_begin_frame (cmacs_libregnum_render_get_shared_window ());
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
        lrg_renderer_end_layer (r->renderer);
        lrg_renderer_end_frame (r->renderer);
      }
  }
  EndTextureMode ();
  lrg_window_end_frame (cmacs_libregnum_render_get_shared_window ());

  Image img = LoadImageFromTexture (r->fbo.texture);
  if (!img.data || img.width != r->width || img.height != r->height)
    {
      UnloadImage (img);
      return FALSE;
    }
  /* raylib renders Y-up to the FBO texture; cairo wants top-down.
   * Flip rows during the RGBA8 -> BGRA convert. */
  const unsigned char *src = (const unsigned char *) img.data;
  int stride = img.width * 4;
  for (int y = 0; y < r->height; y++)
    {
      const unsigned char *sp = src + (r->height - 1 - y) * stride;
      unsigned char       *dp = dst + y * (r->width * 4);
      for (int x = 0; x < r->width; x++)
        {
          dp[0] = sp[2];   /* B */
          dp[1] = sp[1];   /* G */
          dp[2] = sp[0];   /* R */
          dp[3] = sp[3];   /* A */
          sp += 4; dp += 4;
        }
    }
  UnloadImage (img);
  return TRUE;
}

#include <math.h>

void
cmacs_libregnum_render_ctx_orbit_camera (CmacsLibregnumRenderCtx *r,
                                         double dx_px, double dy_px)
{
  if (!r || !r->camera || !LRG_IS_CAMERA3D (r->camera)) return;
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
