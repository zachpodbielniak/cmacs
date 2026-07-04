/* cmacs-gnuseye-overlay-render.c --- weather overlay channels (render half).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Draped raster weather for the GNU's Eye globe: named channels (radar,
 * clouds, ...) whose frames are composed on the CPU -- decode tiles
 * (gdk-pixbuf), paste onto an equirect (or web-mercator, reprojected)
 * canvas, optional luminance->alpha for opaque IR imagery, then the SAME
 * mesh-UV warp the base globe texture went through, so rasters register
 * exactly with the lat/lon marker convention -- and cached as raw RGBA
 * frames under a tag.
 *
 * Display model: the enabled channels are alpha-COMPOSITED (in CPU, in
 * ascending z-order) over a pristine copy of the base globe texture, and
 * the result replaces the globe's albedo via grl_texture_update_rec.
 * There is NO second sphere and NO GPU blending: the albedo stays fully
 * opaque, the day/night shader applies to the weather automatically, the
 * drape rotates with the globe by construction, and markers/polygons/
 * labels draw over it exactly as they do over geography.  (A translucent
 * shell prototype hit alpha-blend sampling artifacts in the par_shapes
 * pole zones; compositing into the proven base-texture path eliminates
 * that entire class.)  Animation stepping = re-composite + one texture
 * upload, a few milliseconds at the 640x1280 globe-texture size.
 *
 * Translation-unit firewall: a render-half TU like cmacs-gnuseye-globe.c
 * -- includes <libregnum.h>, NEVER lisp.h.  All GL work happens in DEFUN
 * context, i.e. on the main thread where the raylib GL context is
 * current.
 *
 * Lifetime: all channel state hangs off the background GrlModel as
 * qdata, so a globe rebuild (projection flip) or view teardown frees it
 * automatically. */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "cmacs-gnuseye-overlay.h"
#include "cmacs-gnuseye-globe.h"
#include "cmacs-gnuseye-geomath.h"
#include "cmacs-libregnum-render.h"
#include <gdk-pixbuf/gdk-pixbuf.h>

#include <libregnum.h>
#include <glib.h>
#include <math.h>
#include <string.h>

#include "cmacs-gnuseye-render-internal.h"

#define WX_QDATA_KEY        "gnuseye-wx-overlays"
#define WX_DEFAULT_CACHE    (64 * 1024 * 1024)
#define WX_MAX_CANVAS       8192
#define WX_MERC_MAX_LAT     85.05112878

/* Per-channel state: cached warped frames + display parameters.  Frames
 * are stored in the base texture's mesh-UV layout, ready to composite. */
typedef struct
{
  gchar      *name;
  double      z_order;           /* higher composites over lower */
  double      alpha;             /* 0..1 opacity multiplier */
  gboolean    enabled;
  GHashTable *frames;            /* gchar* tag -> GBytes (tw*th*4) */
  GQueue      lru;               /* gchar* tags, most recent at head */
  gsize       cache_bytes;
  gsize       cache_cap;
  gchar      *current_tag;       /* frame being displayed, or NULL */
} GnuseyeWxChannel;

/* Per-globe holder: the pristine base pixels + the channel list. */
typedef struct
{
  GBytes    *pristine;           /* base albedo before any weather */
  int        tw, th;             /* base texture dims */
  guint32   *lut;                /* canvas -> mesh-UV warp gather table */
  int        lut_sw, lut_sh;     /* canvas dims the LUT was built for */
  GPtrArray *channels;           /* GnuseyeWxChannel*, owned */
} GnuseyeWxState;

static void
wx_channel_free (gpointer p)
{
  GnuseyeWxChannel *c = p;
  if (!c) return;
  g_free (c->name);
  if (c->frames) g_hash_table_destroy (c->frames);
  g_queue_clear_full (&c->lru, g_free);
  g_free (c->current_tag);
  g_free (c);
}

static void
wx_state_free (gpointer p)
{
  GnuseyeWxState *s = p;
  if (!s) return;
  if (s->pristine) g_bytes_unref (s->pristine);
  g_free (s->lut);
  if (s->channels) g_ptr_array_unref (s->channels);
  g_free (s);
}

/* The state rides the background model as qdata, so it dies with the
 * globe (rebuild or view teardown) -- no process-static weather state. */
static GnuseyeWxState *
wx_state (CmacsLibregnumRenderCtx *r, gboolean create)
{
  GrlModel *m = r ? cmacs_libregnum_render_ctx_get_background_model (r)
                  : NULL;
  if (!m) return NULL;
  GnuseyeWxState *s = g_object_get_data (G_OBJECT (m), WX_QDATA_KEY);
  if (!s && create)
    {
      GrlImage *img = NULL;
      GrlTexture *tex = NULL;
      if (!cmacs_gnuseye_globe_master (r, &img, &tex) || !img || !tex)
        return NULL;
      gsize isz = 0;
      guint8 *px = grl_image_get_pixels (img, &isz);
      int tw = grl_image_get_width (img), th = grl_image_get_height (img);
      if (!px || tw <= 0 || th <= 0
          || isz < (gsize) tw * (gsize) th * 4)
        return NULL;
      s = g_new0 (GnuseyeWxState, 1);
      s->pristine = g_bytes_new (px, (gsize) tw * (gsize) th * 4);
      s->tw = tw;
      s->th = th;
      s->channels = g_ptr_array_new_with_free_func (wx_channel_free);
      g_object_set_data_full (G_OBJECT (m), WX_QDATA_KEY, s, wx_state_free);
    }
  return s;
}

static GnuseyeWxChannel *
wx_find (CmacsLibregnumRenderCtx *r, const char *name)
{
  GnuseyeWxState *s = wx_state (r, FALSE);
  if (!s || !name) return NULL;
  for (guint i = 0; i < s->channels->len; i++)
    {
      GnuseyeWxChannel *c = g_ptr_array_index (s->channels, i);
      if (g_strcmp0 (c->name, name) == 0) return c;
    }
  return NULL;
}

/* ── Composite + upload ─────────────────────────────────────────────── */

/* Rebuild the globe albedo = pristine base with every enabled channel's
 * current frame srcOver-composited in ascending z-order, and upload it.
 * A few ms at 640x1280; called from DEFUN context (GL current). */
static void
wx_recomposite (CmacsLibregnumRenderCtx *r)
{
  GnuseyeWxState *s = wx_state (r, FALSE);
  if (!s || !s->pristine) return;
  GrlImage *img = NULL;
  GrlTexture *tex = NULL;
  if (!cmacs_gnuseye_globe_master (r, &img, &tex) || !tex) return;

  gsize bsz = 0;
  const guint8 *base = g_bytes_get_data (s->pristine, &bsz);
  gsize need = (gsize) s->tw * (gsize) s->th * 4;
  if (!base || bsz < need) return;
  guint8 *out = g_malloc (need);
  memcpy (out, base, need);

  /* Ascending z-order (stable insertion sort over a handful). */
  guint n = s->channels->len;
  for (guint i = 1; i < n; i++)
    for (guint j = i; j > 0; j--)
      {
        GnuseyeWxChannel *a = g_ptr_array_index (s->channels, j - 1);
        GnuseyeWxChannel *b = g_ptr_array_index (s->channels, j);
        if (a->z_order <= b->z_order) break;
        s->channels->pdata[j - 1] = b;
        s->channels->pdata[j] = a;
      }

  for (guint ci = 0; ci < n; ci++)
    {
      GnuseyeWxChannel *c = g_ptr_array_index (s->channels, ci);
      if (!c->enabled || c->alpha <= 0.0 || !c->current_tag) continue;
      GBytes *fb = g_hash_table_lookup (c->frames, c->current_tag);
      if (!fb) continue;
      gsize fsz = 0;
      const guint8 *fr = g_bytes_get_data (fb, &fsz);
      if (!fr || fsz < need) continue;
      int chalpha = (int) (c->alpha * 255.0 + 0.5);
      gsize texels = (gsize) s->tw * (gsize) s->th;
      for (gsize i = 0; i < texels; i++)
        {
          const guint8 *sp = fr + i * 4;
          int a = (sp[3] * chalpha) / 255;
          if (a <= 0) continue;
          guint8 *dp = out + i * 4;
          if (a >= 255)
            {
              dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2];
            }
          else
            {
              int ia = 255 - a;
              dp[0] = (guint8) ((sp[0] * a + dp[0] * ia) / 255);
              dp[1] = (guint8) ((sp[1] * a + dp[1] * ia) / 255);
              dp[2] = (guint8) ((sp[2] * a + dp[2] * ia) / 255);
            }
        }
    }

  g_autoptr (GrlRectangle) rect =
    grl_rectangle_new (0.0f, 0.0f, (gfloat) s->tw, (gfloat) s->th);
  grl_texture_update_rec (tex, rect, out);
  g_free (out);
}

/* The base texture was swapped ("Earth today"): recapture the pristine
 * copy and re-drape the enabled channels over the new imagery. */
void
cmacs_gnuseye_overlay_base_changed (CmacsLibregnumRenderCtx *r)
{
  GnuseyeWxState *s = wx_state (r, FALSE);
  if (!s) return;
  GrlImage *img = NULL;
  GrlTexture *tex = NULL;
  if (!cmacs_gnuseye_globe_master (r, &img, &tex) || !img) return;
  gsize isz = 0;
  guint8 *px = grl_image_get_pixels (img, &isz);
  int tw = grl_image_get_width (img), th = grl_image_get_height (img);
  if (!px || tw <= 0 || th <= 0 || isz < (gsize) tw * (gsize) th * 4)
    return;
  if (s->pristine) g_bytes_unref (s->pristine);
  s->pristine = g_bytes_new (px, (gsize) tw * (gsize) th * 4);
  if (tw != s->tw || th != s->th)
    {
      /* Dims changed: cached frames no longer fit; drop them. */
      s->tw = tw;
      s->th = th;
      g_free (s->lut);
      s->lut = NULL;
      for (guint i = 0; i < s->channels->len; i++)
        {
          GnuseyeWxChannel *c = g_ptr_array_index (s->channels, i);
          g_hash_table_remove_all (c->frames);
          g_queue_clear_full (&c->lru, g_free);
          g_queue_init (&c->lru);
          c->cache_bytes = 0;
          g_clear_pointer (&c->current_tag, g_free);
        }
    }
  wx_recomposite (r);
}

/* Sun updates are the base globe shader's business now (the weather is
 * IN the albedo); kept as an entry point for the set_sun_direction
 * fan-out call in globe.c. */
void
cmacs_gnuseye_overlay_update_sun (CmacsLibregnumRenderCtx *r,
                                  float x, float y, float z)
{
  (void) r; (void) x; (void) y; (void) z;
}

/* ── Channel lifecycle ──────────────────────────────────────────────── */

gboolean
cmacs_gnuseye_overlay_ensure (CmacsLibregnumRenderCtx *r, const char *name,
                              double radius_scale, int tex_w, int tex_h,
                              gint64 cache_bytes)
{
  (void) tex_w; (void) tex_h;   /* frame size follows the globe texture */
  if (!r || !name || !*name) return FALSE;
  if (!cmacs_gnuseye_built_p (r)) return FALSE;
  /* Draped rasters need the sphere's warped texture; the flat map has
   * neither. */
  if (cmacs_gnuseye_flat_p (r)) return FALSE;

  GnuseyeWxState *s = wx_state (r, TRUE);
  if (!s) return FALSE;

  GnuseyeWxChannel *c = wx_find (r, name);
  if (c)
    {
      if (cache_bytes > 0) c->cache_cap = (gsize) cache_bytes;
      if (radius_scale > 0.0) c->z_order = radius_scale;
      return TRUE;                        /* idempotent */
    }
  c = g_new0 (GnuseyeWxChannel, 1);
  c->name = g_strdup (name);
  c->z_order = radius_scale > 0.0 ? radius_scale : 1.0;
  c->alpha = 1.0;
  c->enabled = TRUE;
  c->frames = g_hash_table_new_full (g_str_hash, g_str_equal, g_free,
                                     (GDestroyNotify) g_bytes_unref);
  g_queue_init (&c->lru);
  c->cache_cap = cache_bytes > 0 ? (gsize) cache_bytes
                                 : (gsize) WX_DEFAULT_CACHE;
  g_ptr_array_add (s->channels, c);
  return TRUE;
}

gboolean
cmacs_gnuseye_overlay_exists_p (CmacsLibregnumRenderCtx *r, const char *name)
{
  return wx_find (r, name) != NULL;
}

void
cmacs_gnuseye_overlay_clear (CmacsLibregnumRenderCtx *r, const char *name)
{
  GnuseyeWxState *s = wx_state (r, FALSE);
  if (!s) return;
  if (name)
    {
      for (guint i = 0; i < s->channels->len; i++)
        {
          GnuseyeWxChannel *c = g_ptr_array_index (s->channels, i);
          if (g_strcmp0 (c->name, name) == 0)
            {
              g_ptr_array_remove_index (s->channels, i);
              break;
            }
        }
    }
  else
    g_ptr_array_set_size (s->channels, 0);
  wx_recomposite (r);
}

gboolean
cmacs_gnuseye_overlay_set_alpha (CmacsLibregnumRenderCtx *r,
                                 const char *name, double alpha)
{
  GnuseyeWxChannel *c = wx_find (r, name);
  if (!c) return FALSE;
  if (alpha < 0.0) alpha = 0.0;
  if (alpha > 1.0) alpha = 1.0;
  c->alpha = alpha;
  wx_recomposite (r);
  return TRUE;
}

gboolean
cmacs_gnuseye_overlay_set_enabled (CmacsLibregnumRenderCtx *r,
                                   const char *name, gboolean enabled)
{
  GnuseyeWxChannel *c = wx_find (r, name);
  if (!c) return FALSE;
  c->enabled = enabled;
  wx_recomposite (r);
  return TRUE;
}

/* ── Compose pipeline ───────────────────────────────────────────────── */

/* Decode PATH into a tight, newly-allocated RGBA8 buffer. */
static guint8 *
wx_decode_rgba (const char *path, int *out_w, int *out_h)
{
  g_autoptr (GError) err = NULL;
  GdkPixbuf *pb = gdk_pixbuf_new_from_file (path, &err);
  if (!pb)
    {
      g_warning ("gnuseye overlay: cannot decode %s: %s", path,
                 err ? err->message : "?");
      return NULL;
    }
  if (!gdk_pixbuf_get_has_alpha (pb))
    {
      GdkPixbuf *a = gdk_pixbuf_add_alpha (pb, FALSE, 0, 0, 0);
      g_object_unref (pb);
      if (!a) return NULL;
      pb = a;
    }
  int w = gdk_pixbuf_get_width (pb), h = gdk_pixbuf_get_height (pb);
  int rs = gdk_pixbuf_get_rowstride (pb);
  const guint8 *px = gdk_pixbuf_read_pixels (pb);
  guint8 *tight = NULL;
  if (w > 0 && h > 0 && px)
    {
      tight = g_malloc ((gsize) w * (gsize) h * 4);
      for (int y = 0; y < h; y++)
        memcpy (tight + (gsize) y * w * 4, px + (gsize) y * rs,
                (gsize) w * 4);
      *out_w = w;
      *out_h = h;
    }
  g_object_unref (pb);
  return tight;
}

/* Paste SRC (sw x sh) onto CANVAS (cw x ch) at (dx,dy), nearest-scaled to
 * dw x dh (<= 0: source size), clipped to the canvas.  Replace, not
 * blend: tiles land on a disjoint grid. */
static void
wx_paste (guint8 *canvas, int cw, int ch,
          const guint8 *src, int sw, int sh,
          int dx, int dy, int dw, int dh)
{
  if (dw <= 0) dw = sw;
  if (dh <= 0) dh = sh;
  for (int y = 0; y < dh; y++)
    {
      int cy = dy + y;
      if (cy < 0 || cy >= ch) continue;
      int sy = (int) ((gint64) y * sh / dh);
      if (sy >= sh) sy = sh - 1;
      guint8 *crow = canvas + ((gsize) cy * cw) * 4;
      const guint8 *srow = src + ((gsize) sy * sw) * 4;
      if (dw == sw && dx >= 0 && dx + dw <= cw)
        {
          memcpy (crow + (gsize) dx * 4, srow, (gsize) dw * 4);
          continue;
        }
      for (int x = 0; x < dw; x++)
        {
          int cx = dx + x;
          if (cx < 0 || cx >= cw) continue;
          int sx = (int) ((gint64) x * sw / dw);
          if (sx >= sw) sx = sw - 1;
          memcpy (crow + (gsize) cx * 4, srow + (gsize) sx * 4, 4);
        }
    }
}

/* Reproject a web-mercator canvas (rows spanning +-85.0511 deg) into a
 * fresh equirect canvas of the same dimensions (rows spanning +-90);
 * polar bands beyond mercator coverage stay transparent. */
static guint8 *
wx_mercator_to_equirect (const guint8 *merc, int cw, int ch)
{
  guint8 *eq = g_malloc0 ((gsize) cw * (gsize) ch * 4);
  for (int y = 0; y < ch; y++)
    {
      double lat = 90.0 - ((double) y + 0.5) / ch * 180.0;
      if (fabs (lat) > WX_MERC_MAX_LAT) continue;
      double lr = lat * GNUSEYE_DEG2RAD;
      double my01 = (1.0 - log (tan (M_PI / 4.0 + lr / 2.0)) / M_PI) / 2.0;
      int sy = (int) (my01 * ch);
      if (sy < 0) sy = 0;
      if (sy >= ch) sy = ch - 1;
      memcpy (eq + (gsize) y * cw * 4, merc + (gsize) sy * cw * 4,
              (gsize) cw * 4);
    }
  return eq;
}

/* Map luminance to alpha in place: opaque grayscale IR imagery becomes a
 * translucent cloud drape.  alpha01 = clamp((luma01 - LO) * GAIN); the
 * RGB is recoloured to TINT scaled by luminance (bright tops stay
 * bright), and the tint's own alpha scales the result. */
static void
wx_luma_alpha (guint8 *canvas, int cw, int ch,
               double lo, double gain, guint32 tint_rgba)
{
  guint8 tr = (tint_rgba >> 24) & 0xff, tg = (tint_rgba >> 16) & 0xff;
  guint8 tb = (tint_rgba >> 8) & 0xff,  ta = tint_rgba & 0xff;
  if (ta == 0) ta = 255;
  gsize n = (gsize) cw * ch;
  for (gsize i = 0; i < n; i++)
    {
      guint8 *p = canvas + i * 4;
      if (p[3] == 0) continue;
      double luma = (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) / 255.0;
      double a01 = (luma - lo) * gain;
      if (a01 <= 0.0) { p[0] = p[1] = p[2] = p[3] = 0; continue; }
      if (a01 > 1.0) a01 = 1.0;
      p[0] = (guint8) (tr * luma);
      p[1] = (guint8) (tg * luma);
      p[2] = (guint8) (tb * luma);
      p[3] = (guint8) (a01 * (p[3] / 255.0) * ta);
    }
}

/* Build (or reuse) the warp LUT: for each texel of the mesh-UV globe
 * texture, the source index on a CW x CH equirect canvas.  Same math as
 * cmacs_gnuseye_warp_equirect_to_mesh, hoisted to a gather table so
 * per-frame warps are a single pass of memcpys. */
static void
wx_ensure_lut (GnuseyeWxState *s, int cw, int ch)
{
  if (s->lut && s->lut_sw == cw && s->lut_sh == ch) return;
  g_free (s->lut);
  s->lut = g_malloc ((gsize) s->tw * (gsize) s->th * sizeof (guint32));
  s->lut_sw = cw;
  s->lut_sh = ch;
  int W = s->tw, H = s->th;
  for (int oy = 0; oy < H; oy++)
    {
      double theta = ((double) oy + 0.5) / H * (2.0 * M_PI);
      double st = sin (theta), ct = cos (theta);
      guint32 *lrow = s->lut + (gsize) oy * W;
      for (int ox = 0; ox < W; ox++)
        {
          double phi = ((double) ox + 0.5) / W * M_PI;
          double sp = sin (phi), cp = cos (phi);
          double px = ct * sp, py = st * sp, pz = cp;
          double lat = asin (py < -1 ? -1 : (py > 1 ? 1 : py));
          double lon = atan2 (-pz, px);
          double u = (lon / (2.0 * M_PI)) + 0.5;
          double v = 0.5 - (lat / M_PI);
          int sx = (int) (u * cw), sy = (int) (v * ch);
          if (sx < 0) sx = 0; else if (sx >= cw) sx = cw - 1;
          if (sy < 0) sy = 0; else if (sy >= ch) sy = ch - 1;
          lrow[ox] = (guint32) sy * (guint32) cw + (guint32) sx;
        }
    }
}

/* Evict least-recently-used frames over the cap, never the shown one. */
static void
wx_evict (GnuseyeWxChannel *c)
{
  while (c->cache_bytes > c->cache_cap && c->lru.length > 1)
    {
      GList *tail = c->lru.tail;
      gboolean removed = FALSE;
      while (tail)
        {
          gchar *tag = tail->data;
          GList *prev = tail->prev;
          if (g_strcmp0 (tag, c->current_tag) != 0)
            {
              GBytes *b = g_hash_table_lookup (c->frames, tag);
              if (b) c->cache_bytes -= g_bytes_get_size (b);
              g_hash_table_remove (c->frames, tag);
              g_queue_delete_link (&c->lru, tail);
              g_free (tag);
              removed = TRUE;
              break;
            }
          tail = prev;
        }
      if (!removed) break;                /* only the shown frame remains */
    }
}

/* Move TAG to the LRU head (it exists in the queue). */
static void
wx_touch (GnuseyeWxChannel *c, const char *tag)
{
  for (GList *l = c->lru.head; l; l = l->next)
    if (g_strcmp0 (l->data, tag) == 0)
      {
        gchar *str = l->data;
        g_queue_delete_link (&c->lru, l);
        g_queue_push_head (&c->lru, str);
        return;
      }
}

int
cmacs_gnuseye_overlay_compose_frame (CmacsLibregnumRenderCtx *r,
                                     const char *name, const char *tag,
                                     const CmacsGnuseyeTilePlace *tiles,
                                     int n_tiles,
                                     int canvas_w, int canvas_h,
                                     int projection,
                                     double luma_lo, double luma_gain,
                                     guint32 tint_rgba, gboolean show)
{
  GnuseyeWxState *s = wx_state (r, FALSE);
  GnuseyeWxChannel *c = wx_find (r, name);
  if (!s || !c || !tag || !*tag || !tiles || n_tiles <= 0) return 0;
  if (canvas_w <= 0) canvas_w = 1024;
  if (canvas_h <= 0) canvas_h = 512;
  if (canvas_w > WX_MAX_CANVAS) canvas_w = WX_MAX_CANVAS;
  if (canvas_h > WX_MAX_CANVAS) canvas_h = WX_MAX_CANVAS;

  guint8 *canvas = g_malloc0 ((gsize) canvas_w * (gsize) canvas_h * 4);
  int decoded = 0;
  for (int i = 0; i < n_tiles; i++)
    {
      const CmacsGnuseyeTilePlace *t = &tiles[i];
      if (!t->path || !*t->path) continue;
      int sw = 0, sh = 0;
      guint8 *px = wx_decode_rgba (t->path, &sw, &sh);
      if (!px) continue;                 /* missing tile: stays transparent */
      wx_paste (canvas, canvas_w, canvas_h, px, sw, sh,
                t->dst_x, t->dst_y, t->dst_w, t->dst_h);
      g_free (px);
      decoded++;
    }
  if (decoded == 0)
    {
      g_free (canvas);
      return 0;
    }

  if (projection == CMACS_GNUSEYE_OVERLAY_MERCATOR)
    {
      guint8 *eq = wx_mercator_to_equirect (canvas, canvas_w, canvas_h);
      g_free (canvas);
      canvas = eq;
    }
  if (luma_lo >= 0.0)
    wx_luma_alpha (canvas, canvas_w, canvas_h, luma_lo,
                   luma_gain > 0.0 ? luma_gain : 1.0, tint_rgba);

  wx_ensure_lut (s, canvas_w, canvas_h);
  gsize fsz = (gsize) s->tw * (gsize) s->th * 4;
  guint8 *frame = g_malloc (fsz);
  gsize n = (gsize) s->tw * (gsize) s->th;
  for (gsize i = 0; i < n; i++)
    memcpy (frame + i * 4, canvas + (gsize) s->lut[i] * 4, 4);
  g_free (canvas);

  GBytes *fb = g_bytes_new_take (frame, fsz);
  GBytes *old = g_hash_table_lookup (c->frames, tag);
  if (old)
    {
      c->cache_bytes -= g_bytes_get_size (old);
      g_hash_table_remove (c->frames, tag);
      for (GList *l = c->lru.head; l; l = l->next)
        if (g_strcmp0 (l->data, tag) == 0)
          {
            g_free (l->data);
            g_queue_delete_link (&c->lru, l);
            break;
          }
    }
  g_hash_table_insert (c->frames, g_strdup (tag), fb);
  g_queue_push_head (&c->lru, g_strdup (tag));
  c->cache_bytes += fsz;
  wx_evict (c);

  if (show)
    {
      g_free (c->current_tag);
      c->current_tag = g_strdup (tag);
      wx_recomposite (r);
    }
  return decoded;
}

gboolean
cmacs_gnuseye_overlay_show_frame (CmacsLibregnumRenderCtx *r,
                                  const char *name, const char *tag)
{
  GnuseyeWxChannel *c = wx_find (r, name);
  if (!c || !tag) return FALSE;
  GBytes *b = g_hash_table_lookup (c->frames, tag);
  if (!b) return FALSE;
  wx_touch (c, tag);
  g_free (c->current_tag);
  c->current_tag = g_strdup (tag);
  wx_recomposite (r);
  return TRUE;
}

char **
cmacs_gnuseye_overlay_frame_tags (CmacsLibregnumRenderCtx *r,
                                  const char *name)
{
  GnuseyeWxChannel *c = wx_find (r, name);
  if (!c) return NULL;
  guint n = c->lru.length;
  char **out = g_new0 (char *, n + 1);
  guint i = 0;
  for (GList *l = c->lru.head; l && i < n; l = l->next)
    out[i++] = g_strdup (l->data);
  return out;
}

#endif /* HAVE_CMACS_GNUSEYE */
