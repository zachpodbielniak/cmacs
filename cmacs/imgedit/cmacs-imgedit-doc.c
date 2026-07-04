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

  if (img == NULL)
    return;
  c = lrg_image_canvas_new_for_image (img);
  lrg_image_canvas_set_blend_mode (c, d->draw_blend);
  lrg_image_canvas_draw_line (c, x1, y1, x2, y2, MAX (1, thickness),
                              &d->draw_color);
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
