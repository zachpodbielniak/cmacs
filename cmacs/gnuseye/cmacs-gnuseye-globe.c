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

/* Sun-lit globe shader: a soft day/night terminator from a fixed world sun
 * direction, with the night side kept partly visible (so markers anywhere
 * stay readable) and a cool tint.  Needs no per-frame uniforms beyond the
 * matrices raylib sets automatically -- sunDir is a constant -- so it is
 * built entirely here at globe-build time.  Uniform/attribute names match
 * raylib's auto-detected defaults (mvp/matModel/matNormal/texture0/...). */
static const char *s_globe_vs =
  "#version 330\n"
  "in vec3 vertexPosition;\n"
  "in vec2 vertexTexCoord;\n"
  "in vec3 vertexNormal;\n"
  "in vec4 vertexColor;\n"
  "uniform mat4 mvp;\n"
  "uniform mat4 matModel;\n"
  "uniform mat4 matNormal;\n"
  "out vec2 fragTexCoord;\n"
  "out vec4 fragColor;\n"
  "out vec3 fragNormal;\n"
  "void main(){\n"
  "  fragTexCoord = vertexTexCoord;\n"
  "  fragColor = vertexColor;\n"
  "  fragNormal = normalize(vec3(matNormal*vec4(vertexNormal,1.0)));\n"
  "  gl_Position = mvp*vec4(vertexPosition,1.0);\n"
  "}\n";
static const char *s_globe_fs =
  "#version 330\n"
  "in vec2 fragTexCoord;\n"
  "in vec4 fragColor;\n"
  "in vec3 fragNormal;\n"
  "uniform sampler2D texture0;\n"
  "uniform vec4 colDiffuse;\n"
  "uniform vec3 sunDir;\n"
  "out vec4 finalColor;\n"
  "void main(){\n"
  "  vec3 N = normalize(fragNormal);\n"
  "  vec3 base = (texture(texture0,fragTexCoord)*colDiffuse*fragColor).rgb;\n"
  "  float ndl = dot(N, normalize(sunDir));\n"
  "  float day = smoothstep(-0.35, 0.45, ndl);\n"   /* soft wide terminator */
  "  float shade = 0.40 + 0.60*day;\n"              /* 0.40 night .. 1.0 day */
  "  vec3 c = base*shade;\n"
  "  c = mix(c*vec3(0.55,0.68,1.10), c, day);\n"     /* cool night tint */
  "  finalColor = vec4(min(c,vec3(1.0)),1.0);\n"
  "}\n";

/* Per-globe state attached to the sphere model via g_object_set_data_full,
 * so it is freed when the render ctx releases the background model. */
typedef struct
{
  GrlImage   *img;    /* CPU master (owned) for region recompositing */
  GrlTexture *tex;    /* GPU albedo texture (owned ref) */
  GrlShader  *shader; /* owned ref, or NULL (unlit fallback) */
  int         tw, th; /* texture dimensions */
  double      spin;   /* current spin (degrees) */
} GnuseyeGlobe;

static void
gnuseye_globe_free (gpointer p)
{
  GnuseyeGlobe *g = p;
  if (!g) return;
  g_clear_object (&g->shader);
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

/* ── Real-texture warp ───────────────────────────────────────────────
 * graylib's sphere mesh (raylib GenMeshSphere -> par_shapes) has poles on
 * +-Z and its texcoords transposed vs a standard equirectangular image, so
 * a plain Earth texture does NOT line up with our Y-up lat/lon markers.
 * Rather than rewrite the (intuitive, working) marker convention, we warp
 * the source image ONCE into the mesh's UV space: for each output texel we
 * take the mesh position par_shapes would put there, convert it to our
 * Y-up lat/lon, and sample the source equirectangular Earth.  The result,
 * sampled by the mesh, shows real geography exactly where our markers sit.
 *
 *   par_shapes position(phi,theta) = (cos t sin p, sin t sin p, cos p)
 *   texcoord = (phi/PI, theta/2PI)
 *   our Y-up: lat = asin(y), lon = atan2(z, x) */
#define GLOBE_WARP_W 640
#define GLOBE_WARP_H 1280

static GrlImage *
warp_equirect_to_mesh (GrlImage *src)
{
  int sw = grl_image_get_width (src), sh = grl_image_get_height (src);
  if (sw <= 0 || sh <= 0) return NULL;
  g_autoptr (GrlColor) bg = grl_color_new (8, 22, 50, 255);
  GrlImage *out = grl_image_new_color (GLOBE_WARP_W, GLOBE_WARP_H, bg);
  if (!out) return NULL;
  for (int oy = 0; oy < GLOBE_WARP_H; oy++)
    {
      double theta = ((double) oy + 0.5) / GLOBE_WARP_H * (2.0 * M_PI);
      double st = sin (theta), ct = cos (theta);
      for (int ox = 0; ox < GLOBE_WARP_W; ox++)
        {
          double phi = ((double) ox + 0.5) / GLOBE_WARP_W * M_PI;
          double sp = sin (phi), cp = cos (phi);
          double px = ct * sp, py = st * sp, pz = cp;   /* mesh unit pos */
          double lat = asin (py < -1 ? -1 : (py > 1 ? 1 : py));
          double lon = atan2 (pz, px);
          double u = (lon / (2.0 * M_PI)) + 0.5;         /* 0..1 (lon) */
          double v = 0.5 - (lat / M_PI);                 /* 0 top=north */
          int sx = (int) (u * sw), sy = (int) (v * sh);
          if (sx < 0) sx = 0; else if (sx >= sw) sx = sw - 1;
          if (sy < 0) sy = 0; else if (sy >= sh) sy = sh - 1;
          g_autoptr (GrlColor) col = grl_image_get_pixel (src, sx, sy);
          if (col) grl_image_draw_pixel (out, ox, oy, col);
        }
    }
  return out;
}

/* Load an equirectangular Earth image from PATH and warp it for the mesh.
 * Returns NULL on failure (caller falls back to the procedural globe). */
static GrlImage *
load_earth_texture (const char *path)
{
  if (!path || !*path) return NULL;
  g_autoptr (GrlImage) src = grl_image_new_from_file (path);
  if (!src) return NULL;
  return warp_equirect_to_mesh (src);
}

/* ── Procedural fallback texture ─────────────────────────────────────
 * An equirectangular ocean with a lat/lon graticule and polar caps -- a
 * recognisable, orientation-bearing globe when no Blue-Marble image is
 * supplied.  Pixel mapping: x = (lon+180)/360*W, y = (90-lat)/180*H. */
static GrlImage *
make_procedural_earth (int w, int h)
{
  g_autoptr (GrlColor) seed = grl_color_new (16, 36, 70, 255);
  GrlImage *img = grl_image_new_color (w, h, seed);
  if (!img) return NULL;

  /* Smooth ocean gradient: deep navy at the poles -> brighter teal toward
   * the equator (a per-row fill, cheap and soft). */
  for (int y = 0; y < h; y++)
    {
      double lat = 90.0 - (double) y / h * 180.0;
      double t = cos (lat * GNUSEYE_DEG2RAD);   /* 1 equator .. 0 poles */
      guint8 rr = (guint8) (13 + 16 * t);
      guint8 gg = (guint8) (30 + 44 * t);
      guint8 bb = (guint8) (62 + 52 * t);
      g_autoptr (GrlColor) oc = grl_color_new (rr, gg, bb, 255);
      grl_image_draw_line (img, 0, y, w - 1, y, oc);
    }

  /* Faint graticule -- a reference grid, not a wireframe. */
  g_autoptr (GrlColor) minor = grl_color_new (30, 58, 96, 255);
  g_autoptr (GrlColor) major = grl_color_new (46, 84, 124, 255);
  for (int lat = -80; lat <= 80; lat += 10)
    {
      int y = (int) ((90.0 - lat) / 180.0 * h);
      grl_image_draw_line (img, 0, y, w - 1, y, minor);
    }
  for (int lon = -180; lon <= 180; lon += 15)
    {
      int x = (int) ((lon + 180.0) / 360.0 * w);
      if (x >= w) x = w - 1;
      grl_image_draw_line (img, x, 0, x, h - 1, minor);
    }
  /* Equator + prime/antimeridian a touch brighter (1 px). */
  { int y = h / 2;
    grl_image_draw_line (img, 0, y, w - 1, y, major); }
  for (int lon = -180; lon <= 180; lon += 90)
    {
      int x = (int) ((lon + 180.0) / 360.0 * w);
      if (x >= w) x = w - 1;
      grl_image_draw_line (img, x, 0, x, h - 1, major);
    }

  /* No distinct polar ice band: a UV sphere's pole singularity smears the
   * topmost texture rows into a wide fan, so any bright cap colour shows as
   * an ugly band.  The latitude gradient already darkens the poles, which
   * the pole singularity hides cleanly. */
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
    g->img = load_earth_texture (base_texture_path);
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
    {
      /* Build a lit material: albedo = earth texture, bound to the sun
       * shader.  Falls back to a plain textured model if the shader fails
       * to compile. */
      GrlMaterial *mat = grl_material_new_default ();
      grl_material_set_texture (mat, GRL_MATERIAL_MAP_ALBEDO, g->tex);
      g->shader = grl_shader_new_from_memory (s_globe_vs, s_globe_fs, NULL);
      if (g->shader)
        {
          grl_material_set_shader (mat, g->shader);
          gint loc = grl_shader_get_location (g->shader, "sunDir");
          if (loc >= 0)
            grl_shader_set_value_vec3 (g->shader, loc, 0.90f, 0.25f, -0.35f);
        }
      grl_model_set_material (model, 0, mat);
    }

  g_object_set_data_full (G_OBJECT (model), "gnuseye-globe", g,
                          gnuseye_globe_free);

  /* Transfers ownership of MODEL to the render ctx; its qdata (and thus
   * g->img/g->tex) is freed when the ctx releases the background model. */
  cmacs_libregnum_render_ctx_set_background_model (r, model);
  cmacs_libregnum_render_ctx_set_background_spin (r, 0.0);
  /* The globe occludes labels/flags on its far side. */
  cmacs_libregnum_render_ctx_set_occluder_radius (r, GNUSEYE_GLOBE_RADIUS);
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
  GrlImage *img = load_earth_texture (path);
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

/* ── Markers: oriented 3D icons ─────────────────────────────────────── */

static void
v_norm (double v[3])
{
  double n = sqrt (v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
  if (n > 1e-12) { v[0]/=n; v[1]/=n; v[2]/=n; }
}

static void
v_cross (const double a[3], const double b[3], double o[3])
{
  o[0] = a[1]*b[2] - a[2]*b[1];
  o[1] = a[2]*b[0] - a[0]*b[2];
  o[2] = a[0]*b[1] - a[1]*b[0];
}

/* Euler angles (radians) for the rotation whose columns are (right, up,
 * fwd), matching the Rx*Ry*Rz order LrgShape3D applies at draw time.  The
 * icon is authored in a local frame x=right, y=up, z=forward(travel). */
static void
frame_euler (const double up[3], const double fwd[3], const double right[3],
             float *rx, float *ry, float *rz)
{
  double fx = fwd[0];
  if (fx > 1.0) fx = 1.0; else if (fx < -1.0) fx = -1.0;
  *ry = (float) asin (fx);
  double cb = cos (*ry);
  if (fabs (cb) > 1e-4)
    {
      *rx = (float) atan2 (-fwd[1], fwd[2]);
      *rz = (float) atan2 (-up[0], right[0]);
    }
  else
    {
      *rx = (float) atan2 (right[1], up[1]);
      *rz = 0.0f;
    }
}

/* A solid box of dims (w,h,d) along the local (right,up,fwd) axes, centred
 * at world P + lx*right + ly*up + lz*fwd, oriented by (rx,ry,rz). */
static void
add_box (CmacsLibregnumRenderCtx *r, const double P[3],
         const double R[3], const double U[3], const double F[3],
         float rx, float ry, float rz,
         double lx, double ly, double lz, double w, double h, double d,
         guint8 cr, guint8 cg, guint8 cb, guint8 ca)
{
  double wx = P[0] + lx*R[0] + ly*U[0] + lz*F[0];
  double wy = P[1] + lx*R[1] + ly*U[1] + lz*F[1];
  double wz = P[2] + lx*R[2] + ly*U[2] + lz*F[2];
  LrgCube3D *c = lrg_cube3d_new_at ((gfloat) wx, (gfloat) wy, (gfloat) wz,
                                    (gfloat) w, (gfloat) h, (gfloat) d);
  lrg_shape3d_set_rotation_xyz (LRG_SHAPE3D (c), rx, ry, rz);
  g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, ca);
  lrg_shape_set_color (LRG_SHAPE (c), col);
  cmacs_libregnum_render_ctx_add_drawable (r, c);
}

static void
add_sphere (CmacsLibregnumRenderCtx *r, const double P[3], double radius,
            guint8 cr, guint8 cg, guint8 cb, guint8 ca)
{
  LrgSphere3D *s = lrg_sphere3d_new_at ((gfloat) P[0], (gfloat) P[1],
                                        (gfloat) P[2], (gfloat) radius);
  g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, ca);
  lrg_shape_set_color (LRG_SHAPE (s), col);
  cmacs_libregnum_render_ctx_add_drawable (r, s);
}

/* Vertical altitude exaggeration so markers separate visibly from the
 * surface (10 km of real aircraft altitude is sub-pixel otherwise).  The
 * detail view still reports the true altitude. */
static double
kind_alt_exag (int kind)
{
  switch (kind)
    {
    case CMACS_GNUSEYE_MARKER_AIRCRAFT:  return 45.0;
    case CMACS_GNUSEYE_MARKER_SATELLITE: return 1.0;
    case CMACS_GNUSEYE_MARKER_LAUNCH:    return 4.0;
    default:                             return 0.0;
    }
}

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
  if (!r) return -1;

  guint8 cr = (rgba >> 24) & 0xff, cg = (rgba >> 16) & 0xff;
  guint8 cb = (rgba >> 8) & 0xff,  ca = rgba & 0xff;
  if (ca == 0) ca = 255;
  double s = 0.11 * (scale > 0 ? scale : 1.0);   /* icon base size */

  /* Local tangent frame: up = surface normal, fwd = travel direction. */
  double up[3], east[3], north[3], fwd[3], right[3];
  gnuseye_enu_basis (lat, lon, up, east, north);
  if (heading >= 0.0)
    {
      double h = heading * GNUSEYE_DEG2RAD, ch = cos (h), sh = sin (h);
      fwd[0] = ch*north[0] + sh*east[0];
      fwd[1] = ch*north[1] + sh*east[1];
      fwd[2] = ch*north[2] + sh*east[2];
    }
  else { fwd[0]=north[0]; fwd[1]=north[1]; fwd[2]=north[2]; }
  v_norm (fwd);
  v_cross (up, fwd, right); v_norm (right);
  float rx, ry, rz;
  frame_euler (up, fwd, right, &rx, &ry, &rz);

  /* Elevated position P (render altitude) and surface point P0. */
  double render_alt = alt_m * kind_alt_exag (kind);
  double P[3], P0[3];
  gnuseye_latlon_to_xyz (lat, lon, render_alt, &P[0], &P[1], &P[2]);
  gnuseye_latlon_to_xyz (lat, lon, 0.0, &P0[0], &P0[1], &P0[2]);
  /* Sit surface icons just above the skin to avoid z-fighting. */
  if (render_alt <= 0.0)
    { P[0]+=up[0]*s*0.5; P[1]+=up[1]*s*0.5; P[2]+=up[2]*s*0.5; }

  switch (kind)
    {
    case CMACS_GNUSEYE_MARKER_AIRCRAFT:
      /* tapered nose + fuselage + swept wings + 2 engines + tailplane +
       * fin (nose at +fwd). */
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,0.62*s,  0.12*s,0.12*s,0.40*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,0,       0.20*s,0.20*s,1.10*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,-0.04*s, 1.62*s,0.05*s,0.36*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, -0.52*s,-0.09*s,0.02*s, 0.13*s,0.13*s,0.34*s, 70,70,80,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz,  0.52*s,-0.09*s,0.02*s, 0.13*s,0.13*s,0.34*s, 70,70,80,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,-0.58*s, 0.66*s,0.05*s,0.22*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.17*s,-0.58*s,0.05*s,0.34*s,0.24*s, cr,cg,cb,ca);
      break;
    case CMACS_GNUSEYE_MARKER_SHIP:
      /* tapered bow + hull + white superstructure + funnel (bow at +fwd). */
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.02*s,0.72*s, 0.22*s,0.17*s,0.32*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,0,        0.40*s,0.20*s,1.30*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.20*s,-0.15*s,0.28*s,0.22*s,0.45*s, 235,235,245,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.40*s,-0.30*s,0.10*s,0.20*s,0.12*s, 60,60,70,ca);
      break;
    case CMACS_GNUSEYE_MARKER_SATELLITE:
      /* body + two solar panels along the right axis. */
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,0,        0.32*s,0.30*s,0.42*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, -0.78*s,0,0,  0.75*s,0.04*s,0.55*s, 40,90,160,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz,  0.78*s,0,0,  0.75*s,0.04*s,0.55*s, 40,90,160,ca);
      break;
    case CMACS_GNUSEYE_MARKER_LAUNCH:
      /* upright rocket: body + nose. */
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.45*s,0,   0.18*s,0.95*s,0.18*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,1.02*s,0,   0.13*s,0.22*s,0.13*s, 255,255,255,ca);
      break;
    case CMACS_GNUSEYE_MARKER_QUAKE:
      /* magnitude-sized glowing sphere. */
      add_sphere (r, P, 0.9*s, cr,cg,cb,ca);
      break;
    case CMACS_GNUSEYE_MARKER_FIRE:
      /* small flame: tapered stack of boxes. */
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.18*s,0,   0.35*s,0.36*s,0.35*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.45*s,0,   0.18*s,0.30*s,0.18*s, 255,230,120,ca);
      break;
    case CMACS_GNUSEYE_MARKER_CAMERA:
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,0,        0.4*s,0.3*s,0.5*s, cr,cg,cb,ca);
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0,0.35*s,   0.18*s,0.18*s,0.2*s, 30,30,40,ca);
      break;
    case CMACS_GNUSEYE_MARKER_CITY:
    default:
      /* pin: stalk + bead. */
      add_box (r, P, right, up, fwd, rx,ry,rz, 0,0.18*s,0,   0.05*s,0.36*s,0.05*s, cr,cg,cb,ca);
      { double bead[3] = { P[0]+up[0]*0.42*s, P[1]+up[1]*0.42*s,
                           P[2]+up[2]*0.42*s };
        add_sphere (r, bead, 0.12*s, cr,cg,cb,ca); }
      break;
    }

  /* Drop-line from an elevated marker to its ground point: reads altitude
   * and pins the marker to a lat/lon, like a flight tracker. */
  if (render_alt > 0.0)
    {
      LrgLine3D *drop = lrg_line3d_new_from_to (
        (gfloat) P[0], (gfloat) P[1], (gfloat) P[2],
        (gfloat) P0[0], (gfloat) P0[1], (gfloat) P0[2]);
      g_autoptr (GrlColor) dc = grl_color_new (cr, cg, cb, 70);
      lrg_shape_set_color (LRG_SHAPE (drop), dc);
      cmacs_libregnum_render_ctx_add_drawable (r, drop);
    }

  /* Pickable node at the icon centre, AABB sized to the icon. */
  float hw = (gfloat) (s * 1.1);
  guint nid = cmacs_libregnum_render_ctx_add_node (r, id, label, FALSE, 0, -1,
                                                   (gfloat) P[0], (gfloat) P[1],
                                                   (gfloat) P[2], hw, hw, hw);
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

/* ── Coastline overlay (vector continents, our convention) ──────────── */

#define COAST_LIFT_M 9000.0   /* lift coastlines just above the ocean skin */

void
cmacs_gnuseye_add_coastline (CmacsLibregnumRenderCtx *r,
                             const double *lats, const double *lons,
                             int n, unsigned int rgba)
{
  if (!r || !lats || !lons || n < 2) return;
  guint8 cr = (rgba >> 24) & 0xff, cg = (rgba >> 16) & 0xff;
  guint8 cb = (rgba >> 8) & 0xff,  ca = rgba & 0xff;
  if (ca == 0) ca = 255;
  for (int i = 0; i + 1 < n; i++)
    {
      double x0, y0, z0, x1, y1, z1;
      gnuseye_latlon_to_xyz (lats[i], lons[i], COAST_LIFT_M, &x0, &y0, &z0);
      gnuseye_latlon_to_xyz (lats[i+1], lons[i+1], COAST_LIFT_M,
                             &x1, &y1, &z1);
      LrgLine3D *seg =
        lrg_line3d_new_from_to ((gfloat) x0, (gfloat) y0, (gfloat) z0,
                                (gfloat) x1, (gfloat) y1, (gfloat) z1);
      g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, ca);
      lrg_shape_set_color (LRG_SHAPE (seg), col);
      cmacs_libregnum_render_ctx_add_static_drawable (r, seg);
    }
}

void
cmacs_gnuseye_clear_coastlines (CmacsLibregnumRenderCtx *r)
{
  if (r) cmacs_libregnum_render_ctx_clear_static_drawables (r);
}

/* ── Country flags (camera-facing billboards) ───────────────────────── */

#define FLAG_LIFT_M 25000.0

int
cmacs_gnuseye_add_flag (CmacsLibregnumRenderCtx *r, double lat, double lon,
                        const char *flag_path, double size)
{
  if (!r || !flag_path) return -1;
  GrlTexture *tex = grl_texture_new_from_file (flag_path);
  if (!tex) return -1;
  double x, y, z;
  gnuseye_latlon_to_xyz (lat, lon, FLAG_LIFT_M, &x, &y, &z);
  cmacs_libregnum_render_ctx_add_billboard (r, (float) x, (float) y, (float) z,
                                            tex, (float) (size > 0 ? size
                                                                   : 0.25));
  return 0;
}

void
cmacs_gnuseye_clear_flags (CmacsLibregnumRenderCtx *r)
{
  if (r) cmacs_libregnum_render_ctx_clear_billboards (r);
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
