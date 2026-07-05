/* cmacs-imgedit-doc.c --- libregnum image-document bridge.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The only imgedit TU that includes <libregnum.h>; wraps LrgImageDocument /
 * LrgImageLayer / LrgImageCanvas behind the plain-C cmacs-imgedit-doc.h API
 * so the DEFUN layer never sees raylib's `Color' typedef. */

#include <config.h>

#ifdef HAVE_CMACS_IMGEDIT

#include "cmacs-imgedit-doc.h"
#include <libregnum.h>
#include <math.h>

struct CmacsImgeditDoc
{
  LrgImageDocument *doc;
  GrlImageBlendMode draw_blend;  /* blend mode for canvas drawing tools */
  GrlColor          draw_color;  /* current colour for the shape tools */
};

CmacsImgeditDoc *
cmacs_imgedit_doc_new (int w, int h)
{
  CmacsImgeditDoc *d;

  if (w <= 0 || h <= 0)
    return NULL;
  d = g_new0 (CmacsImgeditDoc, 1);
  d->doc = lrg_image_document_new (w, h);
  d->draw_blend = GRL_IMAGE_BLEND_OVER;
  d->draw_color.r = 0; d->draw_color.g = 0; d->draw_color.b = 0;
  d->draw_color.a = 255;
  return d;
}

CmacsImgeditDoc *
cmacs_imgedit_doc_new_from_file (const char *path, char **error_msg)
{
  CmacsImgeditDoc *d;
  GrlImage *img;

  img = grl_image_new_from_file (path);
  if (img == NULL || grl_image_get_width (img) <= 0)
    {
      if (error_msg)
        *error_msg = g_strdup_printf ("could not load image '%s'", path);
      g_clear_object (&img);
      return NULL;
    }
  d = g_new0 (CmacsImgeditDoc, 1);
  d->doc = lrg_image_document_new_from_image (img);
  d->draw_blend = GRL_IMAGE_BLEND_OVER;
  d->draw_color.r = 0; d->draw_color.g = 0; d->draw_color.b = 0;
  d->draw_color.a = 255;
  g_object_unref (img);
  return d;
}

void
cmacs_imgedit_doc_free (CmacsImgeditDoc *d)
{
  if (d == NULL)
    return;
  g_clear_object (&d->doc);
  g_free (d);
}

int
cmacs_imgedit_doc_width (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_get_width (d->doc) : 0;
}

int
cmacs_imgedit_doc_height (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_get_height (d->doc) : 0;
}

guint
cmacs_imgedit_doc_n_layers (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_get_n_layers (d->doc) : 0;
}

guint
cmacs_imgedit_doc_add_layer (CmacsImgeditDoc *d, const char *name)
{
  return d ? lrg_image_document_add_layer (d->doc, name) : 0;
}

gint
cmacs_imgedit_doc_add_layer_from_file (CmacsImgeditDoc *d, const char *path,
                                       const char *name, char **error_msg)
{
  GrlImage *img;
  guint idx;

  if (d == NULL)
    return -1;
  img = grl_image_new_from_file (path);
  if (img == NULL || grl_image_get_width (img) <= 0)
    {
      if (error_msg)
        *error_msg = g_strdup_printf ("could not load image '%s'", path);
      g_clear_object (&img);
      return -1;
    }
  idx = lrg_image_document_add_layer_for_image (d->doc, img, name);
  g_object_unref (img);
  return (gint) idx;
}

gint
cmacs_imgedit_doc_add_layer_rgba (CmacsImgeditDoc *d, int w, int h,
                                  const guint8 *rgba, gsize n,
                                  const char *name)
{
  GrlImage *img;
  guint idx;

  if (d == NULL || rgba == NULL || w <= 0 || h <= 0)
    return -1;
  if (n < (gsize) w * h * 4)
    return -1;
  img = grl_image_new_from_pixels (w, h,
                                   GRL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, rgba);
  if (img == NULL)
    return -1;
  idx = lrg_image_document_add_layer_for_image (d->doc, img, name);
  g_object_unref (img);
  return (gint) idx;
}

gboolean
cmacs_imgedit_doc_remove_layer (CmacsImgeditDoc *d, guint idx)
{
  return d ? lrg_image_document_remove_layer (d->doc, idx) : FALSE;
}

gboolean
cmacs_imgedit_doc_move_layer (CmacsImgeditDoc *d, guint from, guint to)
{
  return d ? lrg_image_document_move_layer (d->doc, from, to) : FALSE;
}

gint
cmacs_imgedit_doc_duplicate_layer (CmacsImgeditDoc *d, guint idx)
{
  return d ? lrg_image_document_duplicate_layer (d->doc, idx) : -1;
}

guint
cmacs_imgedit_doc_active (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_get_active_index (d->doc) : 0;
}

void
cmacs_imgedit_doc_set_active (CmacsImgeditDoc *d, guint idx)
{
  if (d)
    lrg_image_document_set_active_index (d->doc, idx);
}

static LrgImageLayer *
layer_at (CmacsImgeditDoc *d, guint idx)
{
  return d ? lrg_image_document_get_layer (d->doc, idx) : NULL;
}

const char *
cmacs_imgedit_doc_layer_name (CmacsImgeditDoc *d, guint idx)
{
  LrgImageLayer *l = layer_at (d, idx);
  return l ? lrg_image_layer_get_name (l) : NULL;
}

void
cmacs_imgedit_doc_set_layer_name (CmacsImgeditDoc *d, guint idx,
                                  const char *name)
{
  LrgImageLayer *l = layer_at (d, idx);
  if (l)
    lrg_image_layer_set_name (l, name);
}

double
cmacs_imgedit_doc_layer_opacity (CmacsImgeditDoc *d, guint idx)
{
  LrgImageLayer *l = layer_at (d, idx);
  return l ? lrg_image_layer_get_opacity (l) : 1.0;
}

void
cmacs_imgedit_doc_set_layer_opacity (CmacsImgeditDoc *d, guint idx, double o)
{
  LrgImageLayer *l = layer_at (d, idx);
  if (l)
    {
      lrg_image_layer_set_opacity (l, (gfloat) o);
      lrg_image_document_mark_dirty (d->doc);
    }
}

gint
cmacs_imgedit_doc_layer_blend (CmacsImgeditDoc *d, guint idx)
{
  LrgImageLayer *l = layer_at (d, idx);
  return l ? (gint) lrg_image_layer_get_blend_mode (l) : 0;
}

void
cmacs_imgedit_doc_set_layer_blend (CmacsImgeditDoc *d, guint idx, gint mode)
{
  LrgImageLayer *l = layer_at (d, idx);
  if (l)
    {
      lrg_image_layer_set_blend_mode (l, (GrlImageBlendMode) mode);
      lrg_image_document_mark_dirty (d->doc);
    }
}

gboolean
cmacs_imgedit_doc_layer_visible (CmacsImgeditDoc *d, guint idx)
{
  LrgImageLayer *l = layer_at (d, idx);
  return l ? lrg_image_layer_get_visible (l) : FALSE;
}

void
cmacs_imgedit_doc_set_layer_visible (CmacsImgeditDoc *d, guint idx, gboolean v)
{
  LrgImageLayer *l = layer_at (d, idx);
  if (l)
    {
      lrg_image_layer_set_visible (l, v);
      lrg_image_document_mark_dirty (d->doc);
    }
}

gboolean
cmacs_imgedit_doc_layer_locked (CmacsImgeditDoc *d, guint idx)
{
  LrgImageLayer *l = layer_at (d, idx);
  return l && lrg_image_layer_get_locked (l);
}

void
cmacs_imgedit_doc_set_layer_locked (CmacsImgeditDoc *d, guint idx, gboolean v)
{
  LrgImageLayer *l = layer_at (d, idx);
  if (l)
    lrg_image_layer_set_locked (l, v);
}

void
cmacs_imgedit_doc_layer_offset (CmacsImgeditDoc *d, guint idx, int *x, int *y)
{
  LrgImageLayer *l = layer_at (d, idx);
  if (l)
    lrg_image_layer_get_offset (l, x, y);
}

void
cmacs_imgedit_doc_set_layer_offset (CmacsImgeditDoc *d, guint idx, int x, int y)
{
  LrgImageLayer *l = layer_at (d, idx);
  if (l)
    {
      lrg_image_layer_set_offset (l, x, y);
      lrg_image_document_mark_dirty (d->doc);
    }
}

/* The active layer's backing image, or NULL if none / locked. */
static GrlImage *
editable_image (CmacsImgeditDoc *d)
{
  LrgImageLayer *l;

  if (d == NULL)
    return NULL;
  l = lrg_image_document_get_active_layer (d->doc);
  if (l == NULL || lrg_image_layer_get_locked (l))
    return NULL;
  return lrg_image_layer_get_image (l);
}

void
cmacs_imgedit_doc_set_draw_blend (CmacsImgeditDoc *d, gint mode)
{
  if (d)
    d->draw_blend = (GrlImageBlendMode) mode;
}

void
cmacs_imgedit_doc_fill (CmacsImgeditDoc *d,
                        guint8 r, guint8 g, guint8 b, guint8 a)
{
  GrlImage *img = editable_image (d);
  GrlColor col;

  if (img == NULL)
    return;
  col.r = r; col.g = g; col.b = b; col.a = a;
  grl_image_clear_background (img, &col);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_set_pixel (CmacsImgeditDoc *d, int x, int y,
                             guint8 r, guint8 g, guint8 b, guint8 a)
{
  GrlImage *img = editable_image (d);
  GrlColor col;

  if (img == NULL)
    return;
  col.r = r; col.g = g; col.b = b; col.a = a;
  grl_image_draw_pixel (img, x, y, &col);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_set_color (CmacsImgeditDoc *d,
                             guint8 r, guint8 g, guint8 b, guint8 a)
{
  if (d == NULL)
    return;
  d->draw_color.r = r;
  d->draw_color.g = g;
  d->draw_color.b = b;
  d->draw_color.a = a;
}

void
cmacs_imgedit_doc_draw_line (CmacsImgeditDoc *d, int x1, int y1, int x2, int y2,
                             int thickness)
{
  GrlImage *img = editable_image (d);
  g_autoptr (LrgImageCanvas) c = NULL;
  int t;

  if (img == NULL)
    return;
  t = MAX (1, thickness);
  c = lrg_image_canvas_new_for_image (img);
  lrg_image_canvas_set_blend_mode (c, d->draw_blend);
  lrg_image_canvas_draw_line (c, x1, y1, x2, y2, t, &d->draw_color);
  /* raylib's thick-line rasterizer can leave the very endpoints
     unpainted; cap both ends so a stroke reaches exactly where the
     user pressed and released (pixel-art fidelity, smooth brush
     segment joins).  */
  if (t <= 1)
    {
      lrg_image_canvas_fill_rect (c, x1, y1, 1, 1, &d->draw_color);
      lrg_image_canvas_fill_rect (c, x2, y2, 1, 1, &d->draw_color);
    }
  else
    {
      lrg_image_canvas_fill_circle (c, x1, y1, t / 2, &d->draw_color);
      lrg_image_canvas_fill_circle (c, x2, y2, t / 2, &d->draw_color);
    }
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_draw_rect (CmacsImgeditDoc *d, int x, int y, int w, int h,
                             gboolean filled, int thickness)
{
  GrlImage *img = editable_image (d);
  g_autoptr (LrgImageCanvas) c = NULL;

  if (img == NULL)
    return;
  c = lrg_image_canvas_new_for_image (img);
  lrg_image_canvas_set_blend_mode (c, d->draw_blend);
  if (filled)
    {
      lrg_image_canvas_fill_rect (c, x, y, w, h, &d->draw_color);
    }
  else
    {
      int t = MAX (1, thickness);
      lrg_image_canvas_draw_line (c, x, y, x + w, y, t, &d->draw_color);
      lrg_image_canvas_draw_line (c, x + w, y, x + w, y + h, t, &d->draw_color);
      lrg_image_canvas_draw_line (c, x + w, y + h, x, y + h, t, &d->draw_color);
      lrg_image_canvas_draw_line (c, x, y + h, x, y, t, &d->draw_color);
    }
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_draw_circle (CmacsImgeditDoc *d, int cx, int cy, int radius,
                               gboolean filled, int thickness)
{
  GrlImage *img = editable_image (d);
  g_autoptr (LrgImageCanvas) c = NULL;

  if (img == NULL)
    return;
  c = lrg_image_canvas_new_for_image (img);
  lrg_image_canvas_set_blend_mode (c, d->draw_blend);
  if (filled)
    lrg_image_canvas_fill_circle (c, cx, cy, radius, &d->draw_color);
  else
    lrg_image_canvas_stroke_circle (c, cx, cy, radius, MAX (1, thickness),
                                    &d->draw_color);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_draw_arrow (CmacsImgeditDoc *d, int x1, int y1,
                              int x2, int y2, int thickness)
{
  GrlImage *img = editable_image (d);
  g_autoptr (LrgImageCanvas) c = NULL;
  double dx, dy, len, ux, uy, px, py, head, cross;
  GrlVector2 tip, b1, b2, tmp;

  if (img == NULL)
    return;
  dx = x2 - x1;
  dy = y2 - y1;
  len = sqrt (dx * dx + dy * dy);
  if (len < 1.0)
    return;
  ux = dx / len;
  uy = dy / len;
  px = -uy;                     /* perpendicular unit vector */
  py = ux;
  head = MAX (6.0, 3.0 * MAX (1, thickness));
  head = MIN (head, len);

  c = lrg_image_canvas_new_for_image (img);
  lrg_image_canvas_set_blend_mode (c, d->draw_blend);
  /* Shaft stops where the head begins so a thick line never pokes out. */
  lrg_image_canvas_draw_line (c, x1, y1,
                              (int) (x2 - ux * head), (int) (y2 - uy * head),
                              MAX (1, thickness), &d->draw_color);

  tip.x = (gfloat) x2;
  tip.y = (gfloat) y2;
  b1.x = (gfloat) (x2 - ux * head + px * head * 0.5);
  b1.y = (gfloat) (y2 - uy * head + py * head * 0.5);
  b2.x = (gfloat) (x2 - ux * head - px * head * 0.5);
  b2.y = (gfloat) (y2 - uy * head - py * head * 0.5);
  /* raylib fills triangles for one winding only; normalise the vertex
     order so the head shows for every drag direction. */
  cross = ((double) b1.x - tip.x) * ((double) b2.y - tip.y)
        - ((double) b1.y - tip.y) * ((double) b2.x - tip.x);
  if (cross < 0.0)
    {
      tmp = b1;
      b1 = b2;
      b2 = tmp;
    }
  grl_image_draw_triangle (img, &tip, &b1, &b2, &d->draw_color);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_draw_ellipse (CmacsImgeditDoc *d, int cx, int cy,
                                int rx, int ry, gboolean filled, int thickness)
{
  GrlImage *img = editable_image (d);
  GrlImageBlendMode prev;

  if (img == NULL || rx <= 0 || ry <= 0)
    return;
  /* These draw on the raw image (no canvas), so apply the tool blend
     mode there for consistency with the canvas-based shapes. */
  prev = grl_image_get_blend_mode (img);
  grl_image_set_blend_mode (img, d->draw_blend);
  if (filled)
    grl_image_draw_ellipse (img, cx, cy, rx, ry, &d->draw_color);
  else
    grl_image_draw_ellipse_lines (img, cx, cy, rx, ry, MAX (1, thickness),
                                  &d->draw_color);
  grl_image_set_blend_mode (img, prev);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_draw_text (CmacsImgeditDoc *d, int x, int y,
                             const char *text, int size)
{
  GrlImage *img = editable_image (d);
  GrlImageBlendMode prev;

  if (img == NULL || text == NULL || *text == '\0')
    return;
  prev = grl_image_get_blend_mode (img);
  grl_image_set_blend_mode (img, d->draw_blend);
  /* Falls back to the embedded bitmap font when no window exists, so
     this is safe headless. */
  grl_image_draw_text (img, text, x, y, MAX (4, size), &d->draw_color);
  grl_image_set_blend_mode (img, prev);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_flood_fill (CmacsImgeditDoc *d, int x, int y,
                              guint8 r, guint8 g, guint8 b, guint8 a,
                              int tolerance)
{
  GrlImage *img = editable_image (d);
  GrlColor col;

  if (img == NULL)
    return;
  col.r = r; col.g = g; col.b = b; col.a = a;
  grl_image_flood_fill (img, x, y, &col, tolerance);
  lrg_image_document_mark_dirty (d->doc);
}

/* ── Whole-document transforms (all layers) ────────────────────────────
 * Flip is a document-level, dimension-preserving transform, so it applies to
 * every layer (including locked ones); adjustments/filters below apply only to
 * the active layer, matching how raster editors scope "apply filter". */
void
cmacs_imgedit_doc_flip (CmacsImgeditDoc *d, gboolean horizontal)
{
  guint i, n;

  if (d == NULL)
    return;
  n = lrg_image_document_get_n_layers (d->doc);
  for (i = 0; i < n; i++)
    {
      LrgImageLayer *l = lrg_image_document_get_layer (d->doc, i);
      GrlImage *img = l ? lrg_image_layer_get_image (l) : NULL;
      if (img == NULL)
        continue;
      if (horizontal)
        grl_image_flip_horizontal (img);
      else
        grl_image_flip_vertical (img);
    }
  lrg_image_document_mark_dirty (d->doc);
}

/* ── Active-layer colour adjustments ───────────────────────────────────── */
void
cmacs_imgedit_doc_brightness (CmacsImgeditDoc *d, int amount)
{
  GrlImage *img = editable_image (d);
  if (img == NULL) return;
  grl_image_color_brightness (img, amount);      /* -255..255 */
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_contrast (CmacsImgeditDoc *d, double amount)
{
  GrlImage *img = editable_image (d);
  if (img == NULL) return;
  grl_image_color_contrast (img, (gfloat) amount); /* -100..100 */
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_invert (CmacsImgeditDoc *d)
{
  GrlImage *img = editable_image (d);
  if (img == NULL) return;
  grl_image_color_invert (img);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_grayscale (CmacsImgeditDoc *d)
{
  GrlImage *img = editable_image (d);
  if (img == NULL) return;
  grl_image_color_grayscale (img);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_tint (CmacsImgeditDoc *d,
                        guint8 r, guint8 g, guint8 b, guint8 a)
{
  GrlImage *img = editable_image (d);
  GrlColor col;
  if (img == NULL) return;
  col.r = r; col.g = g; col.b = b; col.a = a;
  grl_image_color_tint (img, &col);              /* multiply by tint */
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_color_replace (CmacsImgeditDoc *d,
                                 guint8 fr, guint8 fg, guint8 fb, guint8 fa,
                                 guint8 tr, guint8 tg, guint8 tb, guint8 ta)
{
  GrlImage *img = editable_image (d);
  GrlColor from, to;
  if (img == NULL) return;
  from.r = fr; from.g = fg; from.b = fb; from.a = fa;
  to.r = tr; to.g = tg; to.b = tb; to.a = ta;
  grl_image_color_replace (img, &from, &to);     /* exact-match swap */
  lrg_image_document_mark_dirty (d->doc);
}

/* ── Whole-document geometric transforms (delegate to the document) ─────── */
void
cmacs_imgedit_doc_resize (CmacsImgeditDoc *d, int w, int h, gboolean nearest)
{
  if (d) lrg_image_document_resize (d->doc, w, h, nearest);
}

void
cmacs_imgedit_doc_crop (CmacsImgeditDoc *d, int x, int y, int w, int h)
{
  if (d) lrg_image_document_crop (d->doc, x, y, w, h);
}

void
cmacs_imgedit_doc_rotate (CmacsImgeditDoc *d, gboolean clockwise)
{
  if (d) lrg_image_document_rotate (d->doc, clockwise);
}

/* ── Vector paths: cubic Bézier + SVG import (active layer) ─────────────── */
void
cmacs_imgedit_doc_bezier (CmacsImgeditDoc *d, int x0, int y0, int x1, int y1,
                          int x2, int y2, int x3, int y3, int thickness)
{
  GrlImage *img = editable_image (d);
  g_autoptr (GrlVector2) p0 = NULL, p1 = NULL, p2 = NULL, p3 = NULL;

  if (img == NULL)
    return;
  p0 = grl_vector2_new ((gfloat) x0, (gfloat) y0);
  p1 = grl_vector2_new ((gfloat) x1, (gfloat) y1);
  p2 = grl_vector2_new ((gfloat) x2, (gfloat) y2);
  p3 = grl_vector2_new ((gfloat) x3, (gfloat) y3);
  grl_image_set_blend_mode (img, d->draw_blend);
  grl_image_draw_bezier (img, p0, p1, p2, p3, MAX (1, thickness),
                         &d->draw_color);
  grl_image_set_blend_mode (img, GRL_IMAGE_BLEND_REPLACE);
  lrg_image_document_mark_dirty (d->doc);
}

/* Render an SVG file onto the active layer at DPI (0 -> 96). */
gboolean
cmacs_imgedit_doc_import_svg (CmacsImgeditDoc *d, const char *path,
                             double dpi, char **error_msg)
{
  GrlImage *img = editable_image (d);
  GrlVectorShape **shapes;
  guint n = 0, i;
  g_autoptr (GError) err = NULL;

  if (img == NULL)
    { if (error_msg) *error_msg = g_strdup ("no editable layer"); return FALSE; }
  shapes = grl_svg_load_from_file (path, (gfloat) (dpi > 0 ? dpi : 96.0),
                                   &n, &err);
  if (shapes == NULL)
    { if (error_msg)
        *error_msg = g_strdup (err ? err->message : "SVG parse failed");
      return FALSE; }
  grl_image_set_blend_mode (img, GRL_IMAGE_BLEND_OVER);
  grl_image_draw_svg_shapes (img, shapes, n);
  grl_image_set_blend_mode (img, GRL_IMAGE_BLEND_REPLACE);
  for (i = 0; i < n; i++)
    grl_vector_shape_free (shapes[i]);
  g_free (shapes);
  lrg_image_document_mark_dirty (d->doc);
  return TRUE;
}

/* ── Active-layer gradient fill ────────────────────────────────────────── */
void
cmacs_imgedit_doc_gradient (CmacsImgeditDoc *d, gboolean radial,
                            gboolean vertical,
                            guint8 ar, guint8 ag, guint8 ab, guint8 aa,
                            guint8 br, guint8 bg, guint8 bb, guint8 ba)
{
  GrlImage *img = editable_image (d);
  GrlColor ca, cb;
  int w, h;

  if (img == NULL) return;
  w = grl_image_get_width (img);
  h = grl_image_get_height (img);
  ca.r = ar; ca.g = ag; ca.b = ab; ca.a = aa;
  cb.r = br; cb.g = bg; cb.b = bb; cb.a = ba;
  if (radial)
    grl_image_draw_gradient_radial (img, w / 2, h / 2, (w < h ? w : h) / 2,
                                    &ca, &cb);
  else
    {
      g_autoptr (GrlRectangle) rect =
        grl_rectangle_new (0.0f, 0.0f, (gfloat) w, (gfloat) h);
      grl_image_draw_gradient_rect (img, rect, &ca, &cb,
                                    vertical ? GRL_GRADIENT_AXIS_VERTICAL
                                             : GRL_GRADIENT_AXIS_HORIZONTAL);
    }
  lrg_image_document_mark_dirty (d->doc);
}

/* ── Active-layer filters ──────────────────────────────────────────────── */
void
cmacs_imgedit_doc_blur (CmacsImgeditDoc *d, int radius)
{
  GrlImage *img = editable_image (d);
  if (img == NULL || radius <= 0) return;
  grl_image_blur_box (img, radius);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_bloom (CmacsImgeditDoc *d, int threshold, int blur_radius,
                         double intensity)
{
  GrlImage *img = editable_image (d);
  if (img == NULL) return;
  grl_image_apply_bloom (img, (guint8) threshold, blur_radius,
                         (gfloat) intensity);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_noise (CmacsImgeditDoc *d, double amplitude,
                         double frequency, guint32 seed)
{
  GrlImage *img = editable_image (d);
  if (img == NULL) return;
  grl_image_apply_noise (img, GRL_NOISE_BLEND_OVERLAY, (gfloat) amplitude,
                         (gfloat) frequency, seed);
  lrg_image_document_mark_dirty (d->doc);
}

/* ── Pixel-buffer filters (operate on the active layer's live RGBA8 buffer) ─
 * grl_image_get_pixels returns the tightly-packed, mutable buffer, so these
 * run directly on it with no extra copy (except the convolutions, which read
 * a snapshot).  Alpha is preserved throughout. */

/* Active-layer RGBA8 buffer + dimensions, or NULL. */
static guint8 *
ie_layer_buf (CmacsImgeditDoc *d, int *w, int *h, gsize *n)
{
  GrlImage *img = editable_image (d);
  if (img == NULL)
    return NULL;
  *w = grl_image_get_width (img);
  *h = grl_image_get_height (img);
  return grl_image_get_pixels (img, n);
}

void
cmacs_imgedit_doc_threshold (CmacsImgeditDoc *d, int level)
{
  int w, h; gsize n, i; guint8 *p = ie_layer_buf (d, &w, &h, &n);
  if (p == NULL) return;
  for (i = 0; i + 3 < n; i += 4)
    {
      int luma = (p[i] * 299 + p[i + 1] * 587 + p[i + 2] * 114) / 1000;
      guint8 v = (luma >= level) ? 255 : 0;
      p[i] = p[i + 1] = p[i + 2] = v;      /* alpha p[i+3] kept */
    }
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_posterize (CmacsImgeditDoc *d, int levels)
{
  int w, h, c; gsize n, i; guint8 *p = ie_layer_buf (d, &w, &h, &n);
  if (p == NULL) return;
  if (levels < 2) levels = 2;
  for (i = 0; i + 3 < n; i += 4)
    for (c = 0; c < 3; c++)
      {
        int q = (p[i + c] * (levels - 1) + 127) / 255;   /* nearest bucket */
        p[i + c] = (guint8) (q * 255 / (levels - 1));
      }
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_pixelate (CmacsImgeditDoc *d, int size)
{
  int w, h, bx, by, xx, yy; gsize n; guint8 *p = ie_layer_buf (d, &w, &h, &n);
  if (p == NULL || size < 2) return;
  for (by = 0; by < h; by += size)
    for (bx = 0; bx < w; bx += size)
      {
        long sr = 0, sg = 0, sb = 0, sa = 0, cnt = 0;
        int ex = (bx + size < w) ? bx + size : w;
        int ey = (by + size < h) ? by + size : h;
        for (yy = by; yy < ey; yy++)
          for (xx = bx; xx < ex; xx++)
            { gsize i = ((gsize) yy * w + xx) * 4;
              sr += p[i]; sg += p[i+1]; sb += p[i+2]; sa += p[i+3]; cnt++; }
        if (cnt == 0) continue;
        for (yy = by; yy < ey; yy++)
          for (xx = bx; xx < ex; xx++)
            { gsize i = ((gsize) yy * w + xx) * 4;
              p[i] = sr/cnt; p[i+1] = sg/cnt; p[i+2] = sb/cnt; p[i+3] = sa/cnt; }
      }
  lrg_image_document_mark_dirty (d->doc);
}

/* 3x3 convolution reading a snapshot; alpha preserved.  DIV/BIAS post-scale. */
static void
ie_convolve3 (CmacsImgeditDoc *d, const int k[9], int divisor, int bias)
{
  int w, h, x, y, dx, dy; gsize n; guint8 *p = ie_layer_buf (d, &w, &h, &n);
  guint8 *src;
  if (p == NULL) return;
  if (divisor == 0) divisor = 1;
  src = g_memdup2 (p, n);
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++)
      {
        int cr = 0, cg = 0, cb = 0, ki = 0;
        for (dy = -1; dy <= 1; dy++)
          for (dx = -1; dx <= 1; dx++, ki++)
            {
              int sx = CLAMP (x + dx, 0, w - 1);
              int sy = CLAMP (y + dy, 0, h - 1);
              gsize si = ((gsize) sy * w + sx) * 4;
              cr += src[si] * k[ki];
              cg += src[si + 1] * k[ki];
              cb += src[si + 2] * k[ki];
            }
        gsize i = ((gsize) y * w + x) * 4;
        p[i]     = CLAMP (cr / divisor + bias, 0, 255);
        p[i + 1] = CLAMP (cg / divisor + bias, 0, 255);
        p[i + 2] = CLAMP (cb / divisor + bias, 0, 255);
      }
  g_free (src);
  lrg_image_document_mark_dirty (d->doc);
}

void
cmacs_imgedit_doc_sharpen (CmacsImgeditDoc *d)
{
  static const int k[9] = { 0, -1, 0, -1, 5, -1, 0, -1, 0 };
  ie_convolve3 (d, k, 1, 0);
}

void
cmacs_imgedit_doc_edge_detect (CmacsImgeditDoc *d)
{
  static const int k[9] = { -1, -1, -1, -1, 8, -1, -1, -1, -1 };
  ie_convolve3 (d, k, 1, 0);
}

void
cmacs_imgedit_doc_emboss (CmacsImgeditDoc *d)
{
  static const int k[9] = { -2, -1, 0, -1, 1, 1, 0, 1, 2 };
  ie_convolve3 (d, k, 1, 128);
}

void
cmacs_imgedit_doc_saturation (CmacsImgeditDoc *d, double factor)
{
  int w, h; gsize n, i; guint8 *p = ie_layer_buf (d, &w, &h, &n);
  if (p == NULL) return;
  for (i = 0; i + 3 < n; i += 4)
    {
      double luma = 0.299 * p[i] + 0.587 * p[i + 1] + 0.114 * p[i + 2];
      p[i]     = CLAMP ((int) (luma + (p[i]     - luma) * factor), 0, 255);
      p[i + 1] = CLAMP ((int) (luma + (p[i + 1] - luma) * factor), 0, 255);
      p[i + 2] = CLAMP ((int) (luma + (p[i + 2] - luma) * factor), 0, 255);
    }
  lrg_image_document_mark_dirty (d->doc);
}

gboolean
cmacs_imgedit_doc_get_pixel (CmacsImgeditDoc *d, int x, int y,
                             guint8 *r, guint8 *g, guint8 *b, guint8 *a)
{
  GrlColor col = { 0, 0, 0, 0 };

  if (d == NULL)
    return FALSE;
  if (!lrg_image_document_get_pixel (d->doc, x, y, &col))
    return FALSE;
  if (r) *r = col.r;
  if (g) *g = col.g;
  if (b) *b = col.b;
  if (a) *a = col.a;
  return TRUE;
}

void
cmacs_imgedit_doc_push_undo (CmacsImgeditDoc *d)
{
  if (d)
    lrg_image_document_push_undo (d->doc);
}

gboolean
cmacs_imgedit_doc_undo (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_undo (d->doc) : FALSE;
}

gboolean
cmacs_imgedit_doc_redo (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_redo (d->doc) : FALSE;
}

gboolean
cmacs_imgedit_doc_can_undo (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_can_undo (d->doc) : FALSE;
}

gboolean
cmacs_imgedit_doc_can_redo (CmacsImgeditDoc *d)
{
  return d ? lrg_image_document_can_redo (d->doc) : FALSE;
}

gboolean
cmacs_imgedit_doc_export (CmacsImgeditDoc *d, const char *path,
                          char **error_msg)
{
  GError *err = NULL;

  if (d == NULL)
    return FALSE;
  if (!lrg_image_document_export (d->doc, path, &err))
    {
      if (error_msg)
        *error_msg = g_strdup (err ? err->message : "export failed");
      g_clear_error (&err);
      return FALSE;
    }
  return TRUE;
}

guint8 *
cmacs_imgedit_doc_export_png_bytes (CmacsImgeditDoc *d, gsize *out_n)
{
  GrlImage *flat;

  if (out_n)
    *out_n = 0;
  if (d == NULL)
    return NULL;
  flat = lrg_image_document_flatten (d->doc);
  if (flat == NULL)
    return NULL;
  /* g_malloc'd buffer; caller g_free's. */
  return grl_image_export_to_memory (flat, ".png", out_n);
}

const guint8 *
cmacs_imgedit_doc_flatten_pixels (CmacsImgeditDoc *d, int *w, int *h)
{
  GrlImage *flat;
  gsize n = 0;

  if (d == NULL)
    return NULL;
  flat = lrg_image_document_flatten (d->doc);
  if (flat == NULL)
    return NULL;
  if (w) *w = lrg_image_document_get_width (d->doc);
  if (h) *h = lrg_image_document_get_height (d->doc);
  return grl_image_get_pixels (flat, &n);
}

void *
cmacs_imgedit_doc_document (CmacsImgeditDoc *d)
{
  return d ? (void *) d->doc : NULL;
}

#endif /* HAVE_CMACS_IMGEDIT */
