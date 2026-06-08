/* cmacs-gnuseye-globe.c --- GNU's Eye render half (the only TU that
 * includes <libregnum.h>).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Builds and updates the live globe: a persistent textured Earth sphere
 * (installed as the render context's background model so it survives the
 * per-tick marker rebuilds), heading-oriented surface markers, polyline
 * arcs (orbits / tracks / wakes), and the live-tile region texture.
 *
 * Translation-unit firewall: includes <libregnum.h> + the plain-C render
 * API (cmacs-libregnum-render.h), but NEVER lisp.h/frame.h/buffer.h, just
 * like the cmacs-libregnum-scene-*.c builders.  All globe state hangs off
 * the GrlModel as qdata so it is released automatically when the render
 * context frees its background model. */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "cmacs-gnuseye-globe.h"
#include "cmacs-gnuseye-geomath.h"
#include "cmacs-libregnum-render.h"

#include <libregnum.h>
#include <glib.h>
#include <math.h>

#define GLOBE_TEX_W 2048
#define GLOBE_TEX_H 1024

/* Per-globe state attached to the sphere model via g_object_set_data_full,
 * so it is freed when the render ctx releases the background model. */
typedef struct
{
  GrlImage   *img;    /* CPU master (owned) for region recompositing */
  GrlTexture *tex;    /* GPU albedo texture (owned ref) */
  int         tw, th; /* texture dimensions */
  double      spin;   /* current spin (degrees) */
} GnuseyeGlobe;

static void
gnuseye_globe_free (gpointer p)
{
  GnuseyeGlobe *g = p;
  if (!g) return;
  g_clear_object (&g->tex);
  g_clear_object (&g->img);
  g_free (g);
}

static GnuseyeGlobe *
globe_state (CmacsLibregnumRenderCtx *r)
{
  GrlModel *m = cmacs_libregnum_render_ctx_get_background_model (r);
  return m ? g_object_get_data (G_OBJECT (m), "gnuseye-globe") : NULL;
}

/* ── Procedural fallback texture ─────────────────────────────────────
 * An equirectangular ocean with a lat/lon graticule and polar caps -- a
 * recognisable, orientation-bearing globe when no Blue-Marble image is
 * supplied.  Pixel mapping: x = (lon+180)/360*W, y = (90-lat)/180*H. */
static GrlImage *
make_procedural_earth (int w, int h)
{
  g_autoptr (GrlColor) ocean = grl_color_new (24, 52, 96, 255);
  GrlImage *img = grl_image_new_color (w, h, ocean);
  if (!img) return NULL;

  g_autoptr (GrlColor) grid  = grl_color_new (60, 96, 140, 255);
  g_autoptr (GrlColor) axis  = grl_color_new (110, 150, 200, 255);
  g_autoptr (GrlColor) cap   = grl_color_new (210, 224, 240, 255);

  /* Parallels every 15 degrees; equator brighter. */
  for (int lat = -75; lat <= 75; lat += 15)
    {
      int y = (int) ((90.0 - lat) / 180.0 * h);
      grl_image_draw_line (img, 0, y, w - 1, y, lat == 0 ? axis : grid);
    }
  /* Meridians every 30 degrees; prime meridian brighter. */
  for (int lon = -180; lon <= 180; lon += 30)
    {
      int x = (int) ((lon + 180.0) / 360.0 * w);
      if (x >= w) x = w - 1;
      grl_image_draw_line (img, x, 0, x, h - 1, lon == 0 ? axis : grid);
    }
  /* Polar caps (top/bottom ~10 deg). */
  int cap_h = (int) (10.0 / 180.0 * h);
  for (int y = 0; y < cap_h; y++)
    {
      grl_image_draw_line (img, 0, y, w - 1, y, cap);
      grl_image_draw_line (img, 0, h - 1 - y, w - 1, h - 1 - y, cap);
    }
  return img;
}

/* ── Build / teardown ───────────────────────────────────────────────── */

gboolean
cmacs_gnuseye_build (CmacsLibregnumRenderCtx *r, const char *base_texture_path)
{
  if (!r) return FALSE;

  g_autoptr (GrlMesh) mesh = grl_mesh_new_sphere (GNUSEYE_GLOBE_RADIUS, 48, 96);
  if (!mesh) return FALSE;
  GrlModel *model = grl_model_new_from_mesh (mesh);
  if (!model) return FALSE;

  GnuseyeGlobe *g = g_new0 (GnuseyeGlobe, 1);
  if (base_texture_path && *base_texture_path)
    g->img = grl_image_new_from_file (base_texture_path);
  if (!g->img)
    g->img = make_procedural_earth (GLOBE_TEX_W, GLOBE_TEX_H);
  if (!g->img)
    {
      g_free (g);
      g_object_unref (model);
      return FALSE;
    }
  g->tw = grl_image_get_width (g->img);
  g->th = grl_image_get_height (g->img);
  g->tex = grl_texture_new_from_image (g->img);
  g->spin = 0.0;
  if (g->tex)
    grl_model_set_texture (model, 0, GRL_MATERIAL_MAP_ALBEDO, g->tex);

  g_object_set_data_full (G_OBJECT (model), "gnuseye-globe", g,
                          gnuseye_globe_free);

  /* Transfers ownership of MODEL to the render ctx; its qdata (and thus
   * g->img/g->tex) is freed when the ctx releases the background model. */
  cmacs_libregnum_render_ctx_set_background_model (r, model);
  cmacs_libregnum_render_ctx_set_background_spin (r, 0.0);
  return TRUE;
}

gboolean
cmacs_gnuseye_built_p (CmacsLibregnumRenderCtx *r)
{
  return r && cmacs_libregnum_render_ctx_get_background_model (r) != NULL;
}

gboolean
cmacs_gnuseye_globe_set_base_texture (CmacsLibregnumRenderCtx *r,
                                      const char *path)
{
  GnuseyeGlobe *g = globe_state (r);
  GrlModel *m = cmacs_libregnum_render_ctx_get_background_model (r);
  if (!g || !m || !path) return FALSE;
  GrlImage *img = grl_image_new_from_file (path);
  if (!img) return FALSE;
  g_clear_object (&g->img);
  g_clear_object (&g->tex);
  g->img = img;
  g->tw = grl_image_get_width (img);
  g->th = grl_image_get_height (img);
  g->tex = grl_texture_new_from_image (img);
  if (g->tex)
    grl_model_set_texture (m, 0, GRL_MATERIAL_MAP_ALBEDO, g->tex);
  return TRUE;
}

gboolean
cmacs_gnuseye_globe_update_region (CmacsLibregnumRenderCtx *r,
                                   const unsigned char *rgba, int w, int h,
                                   double lat0, double lon0,
                                   double lat1, double lon1)
{
  GnuseyeGlobe *g = globe_state (r);
  if (!g || !g->tex || !rgba || w <= 0 || h <= 0) return FALSE;

  double latmax = lat0 > lat1 ? lat0 : lat1;
  double lonmin = lon0 < lon1 ? lon0 : lon1;
  double px = (lonmin + 180.0) / 360.0 * g->tw;
  double py = (90.0 - latmax) / 180.0 * g->th;
  if (px < 0) px = 0;
  if (py < 0) py = 0;
  if (px > g->tw - 1) px = g->tw - 1;
  if (py > g->th - 1) py = g->th - 1;

  g_autoptr (GrlRectangle) rect =
    grl_rectangle_new ((gfloat) px, (gfloat) py, (gfloat) w, (gfloat) h);
  grl_texture_update_rec (g->tex, rect, rgba);
  return TRUE;
}

void
cmacs_gnuseye_globe_set_spin (CmacsLibregnumRenderCtx *r, double deg)
{
  GnuseyeGlobe *g = globe_state (r);
  if (g) g->spin = deg;
  cmacs_libregnum_render_ctx_set_background_spin (r, deg);
}

double
cmacs_gnuseye_globe_get_spin (CmacsLibregnumRenderCtx *r)
{
  GnuseyeGlobe *g = globe_state (r);
  return g ? g->spin : 0.0;
}

/* ── Markers + arcs ─────────────────────────────────────────────────── */

void
cmacs_gnuseye_clear_markers (CmacsLibregnumRenderCtx *r)
{
  /* The persistent globe is the background model, not a drawable, so a
   * full drawable clear wipes only the per-tick markers/arcs. */
  if (r) cmacs_libregnum_render_ctx_clear_drawables (r);
}

int
cmacs_gnuseye_add_marker (CmacsLibregnumRenderCtx *r, int kind,
                          double lat, double lon, double alt_m, double heading,
                          double scale, unsigned int rgba,
                          const char *id, const char *label, int label_mode)
{
  (void) kind;
  if (!r) return -1;
  double x, y, z;
  gnuseye_latlon_to_xyz (lat, lon, alt_m, &x, &y, &z);

  double radius = 0.045 * (scale > 0 ? scale : 1.0);
  if (radius < 0.02) radius = 0.02;

  guint8 cr = (rgba >> 24) & 0xff, cg = (rgba >> 16) & 0xff;
  guint8 cb = (rgba >> 8) & 0xff,  ca = rgba & 0xff;
  if (ca == 0) ca = 255;

  LrgSphere3D *s = lrg_sphere3d_new_at ((gfloat) x, (gfloat) y, (gfloat) z,
                                        (gfloat) radius);
  g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, ca);
  lrg_shape_set_color (LRG_SHAPE (s), col);
  cmacs_libregnum_render_ctx_add_drawable (r, s);

  /* Heading tick: a short line from the marker along the travel direction,
   * tangent to the surface -- "drawn in the direction it is travelling". */
  if (heading >= 0.0)
    {
      double fx, fy, fz;
      gnuseye_heading_forward (lat, lon, heading, &fx, &fy, &fz);
      double tlen = radius * 5.0 + 0.12 * (scale > 0 ? scale : 1.0);
      LrgLine3D *tick =
        lrg_line3d_new_from_to ((gfloat) x, (gfloat) y, (gfloat) z,
                                (gfloat) (x + fx * tlen),
                                (gfloat) (y + fy * tlen),
                                (gfloat) (z + fz * tlen));
      g_autoptr (GrlColor) tcol = grl_color_new (cr, cg, cb, 255);
      lrg_shape_set_color (LRG_SHAPE (tick), tcol);
      cmacs_libregnum_render_ctx_add_drawable (r, tick);
    }

  float hw = (gfloat) (radius * 1.8);
  guint nid = cmacs_libregnum_render_ctx_add_node (r, id, label, FALSE, 0, -1,
                                                   (gfloat) x, (gfloat) y,
                                                   (gfloat) z, hw, hw, hw);
  cmacs_libregnum_render_ctx_set_node_label_mode (r, (gint) nid, label_mode);
  return (int) nid;
}

void
cmacs_gnuseye_add_arc (CmacsLibregnumRenderCtx *r,
                       const double *lats, const double *lons,
                       const double *alts, int n, unsigned int rgba)
{
  if (!r || !lats || !lons || n < 2) return;
  guint8 cr = (rgba >> 24) & 0xff, cg = (rgba >> 16) & 0xff;
  guint8 cb = (rgba >> 8) & 0xff,  ca = rgba & 0xff;
  if (ca == 0) ca = 160;
  for (int i = 0; i + 1 < n; i++)
    {
      double x0, y0, z0, x1, y1, z1;
      gnuseye_latlon_to_xyz (lats[i], lons[i], alts ? alts[i] : 0.0,
                             &x0, &y0, &z0);
      gnuseye_latlon_to_xyz (lats[i+1], lons[i+1], alts ? alts[i+1] : 0.0,
                             &x1, &y1, &z1);
      LrgLine3D *seg =
        lrg_line3d_new_from_to ((gfloat) x0, (gfloat) y0, (gfloat) z0,
                                (gfloat) x1, (gfloat) y1, (gfloat) z1);
      g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, ca);
      lrg_shape_set_color (LRG_SHAPE (seg), col);
      cmacs_libregnum_render_ctx_add_drawable (r, seg);
    }
}

/* ── Camera ─────────────────────────────────────────────────────────── */

void
cmacs_gnuseye_camera_goto (CmacsLibregnumRenderCtx *r,
                           double lat, double lon, double range,
                           gboolean animate)
{
  (void) animate;   /* v1: snap; smooth fly-to is a later refinement */
  if (!r) return;
  double dx, dy, dz;
  gnuseye_latlon_to_xyz (lat, lon, 0.0, &dx, &dy, &dz);
  double len = sqrt (dx*dx + dy*dy + dz*dz);
  if (len <= 0) return;
  dx /= len; dy /= len; dz /= len;
  double dist = GNUSEYE_GLOBE_RADIUS + (range > 0 ? range : 12.0);

  double px, py, pz, tx, ty, tz, fov;
  cmacs_libregnum_render_ctx_get_camera_state (r, &px, &py, &pz,
                                               &tx, &ty, &tz, &fov);
  cmacs_libregnum_render_ctx_set_camera_state (r,
                                               dx * dist, dy * dist, dz * dist,
                                               0.0, 0.0, 0.0,
                                               fov > 0 ? fov : 45.0);
}

#endif /* HAVE_CMACS_GNUSEYE */
