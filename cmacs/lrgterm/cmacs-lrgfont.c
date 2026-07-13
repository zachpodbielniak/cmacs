/* cmacs-lrgfont.c --- output_lrg font driver: reuse ftcrfont, paint via atlas.

Copyright (C) 2026 Zach Podbielniak

This file is part of cmacs, a fork of GNU Emacs.

SPDX-License-Identifier: AGPL-3.0-or-later

The lrg backend reuses Emacs's existing FreeType/Cairo font driver
(ftcrfont) for font discovery, opening, metrics and shaping -- everything
EXCEPT the final pixel blit.  We clone ftcrfont_driver and override only its
`draw' method: lrgfont_draw rasterises each glyph through the font's cairo
scaled-font (exactly as ftcrfont does internally) into a small ARGB surface,
converts it to an alpha-coverage mask, uploads it to the per-display
LrgGlyphAtlas, and paints it as a tinted textured quad via the frame's
LrgFrameSurface.  (Proven end to end by the Phase-0 spike.)

Glyphs from colour fonts (CBDT/COLR tables -- e.g. Noto Color Emoji) are
detected per glyph and uploaded as straight (un-premultiplied) RGBA instead
of a coverage mask; the atlas metrics carry is_color, which makes the engine
draw them untinted so the emoji's own colours survive.  */

#include <config.h>

#ifdef HAVE_CMACS_LRGTERM

#include <libregnum.h>
#include <cairo-ft.h>		/* pulls cairo + fontconfig (FcPattern) + FT */
#include <math.h>

#include "lisp.h"
#include "frame.h"
#include "dispextern.h"
#include "character.h"
#include "font.h"
#include "ftfont.h"		/* struct font_info, cr_scaled_font */
#include "cmacs-lrgterm.h"

#define LRG_RED(c)   (((c) >> 16) & 0xff)
#define LRG_GREEN(c) (((c) >> 8) & 0xff)
#define LRG_BLUE(c)  ((c) & 0xff)

/* Return F's display-wide glyph atlas, creating it on first use.  */
LrgGlyphAtlas *
lrg_frame_glyph_atlas (struct frame *f)
{
  struct lrg_display_info *dpyinfo = FRAME_LRG_DISPLAY_INFO (f);

  if (dpyinfo->glyph_atlas == NULL)
    dpyinfo->glyph_atlas = lrg_glyph_atlas_new (1024, 1024);

  return dpyinfo->glyph_atlas;
}

/* Rasterise glyph CODE of SCALED into the atlas under KEY; return its
   metrics (owned by the atlas) or NULL.  Public so the in-engine popup menu
   (cmacs-lrgterm.c) can render label text through the same atlas path.  */
LrgGlyphMetrics *
lrg_font_bake (LrgGlyphAtlas       *atlas,
               cairo_scaled_font_t *scaled,
               unsigned             code,
               const LrgGlyphKey   *key)
{
  cairo_glyph_t cg;
  cairo_text_extents_t ext;
  int w, h, bx, by, adv;
  cairo_surface_t *surf;
  cairo_t *cr;
  unsigned char *data;
  guint8 *rgba;
  int stride, row, col;
  FT_Face ft_face;
  gboolean face_has_color, is_color;
  LrgGlyphMetrics *m;

  cg.index = code;
  cg.x = 0;
  cg.y = 0;
  cairo_scaled_font_glyph_extents (scaled, &cg, 1, &ext);

  bx = (int) floor (ext.x_bearing);
  by = (int) ceil (-ext.y_bearing);
  w = (int) ceil (ext.width);
  h = (int) ceil (ext.height);
  adv = (int) lround (ext.x_advance);

  /* Zero-ink glyph (space etc.): record advance only.  */
  if (w <= 0 || h <= 0)
    return lrg_glyph_atlas_upload (atlas, key, NULL, 0, 0, bx, by, adv, FALSE);

  surf = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, w, h);
  cr = cairo_create (surf);
  cairo_set_source_rgba (cr, 0, 0, 0, 0);
  cairo_set_operator (cr, CAIRO_OPERATOR_SOURCE);
  cairo_paint (cr);
  cairo_set_operator (cr, CAIRO_OPERATOR_OVER);
  cairo_set_scaled_font (cr, scaled);
  cairo_set_source_rgba (cr, 1, 1, 1, 1);
  cg.x = -ext.x_bearing;
  cg.y = -ext.y_bearing;
  cairo_show_glyphs (cr, &cg, 1);
  cairo_surface_flush (surf);

  data = cairo_image_surface_get_data (surf);
  stride = cairo_image_surface_get_stride (surf);

  /* Colour-capable face (CBDT/COLR tables, e.g. Noto Color Emoji)?  Only
     such a face can have painted anything but the white source above, so
     this gates the per-pixel scan and protects ordinary fonts from
     misdetection (component-alpha antialiasing also yields unequal
     channels).  No other cairo call may touch SCALED while locked.  */
  ft_face = cairo_ft_scaled_font_lock_face (scaled);
  face_has_color = ft_face != NULL && FT_HAS_COLOR (ft_face);
  cairo_ft_scaled_font_unlock_face (scaled);

  /* The glyph was painted with an opaque white source, so a monochrome
     glyph's premultiplied BGRA pixels are exactly (a,a,a,a); any channel
     differing from alpha means cairo produced a real colour paint.  Checked
     per glyph because colour fonts may contain colourless glyphs, which
     must stay on the tintable-mask path.  */
  is_color = FALSE;
  if (face_has_color)
    for (row = 0; row < h && !is_color; row++)
      for (col = 0; col < w; col++)
        {
          const guint8 *p = &data[row * stride + col * 4];
          if (p[0] != p[3] || p[1] != p[3] || p[2] != p[3])
            {
              is_color = TRUE;
              break;
            }
        }

  /* Colour glyph: un-premultiply cairo's BGRA into the straight RGBA that
     the engine's GRL_BLEND_ALPHA draw expects (swapping B<->R for the
     atlas's R8G8B8A8 layout); it is drawn untinted.  Otherwise: white +
     alpha-coverage RGBA so the draw-time tint becomes the face foreground
     colour.  */
  rgba = g_malloc0 ((gsize) w * h * 4);
  for (row = 0; row < h; row++)
    for (col = 0; col < w; col++)
      {
        const guint8 *p = &data[row * stride + col * 4];
        guint8 a = p[3];
        guint8 *o = &rgba[(row * w + col) * 4];
        if (is_color)
          {
            o[0] = a ? (guint8) ((p[2] * 255 + a / 2) / a) : 0;
            o[1] = a ? (guint8) ((p[1] * 255 + a / 2) / a) : 0;
            o[2] = a ? (guint8) ((p[0] * 255 + a / 2) / a) : 0;
          }
        else
          {
            o[0] = 255;
            o[1] = 255;
            o[2] = 255;
          }
        o[3] = a;
      }

  m = lrg_glyph_atlas_upload (atlas, key, rgba, w, h, bx, by, adv, is_color);

  g_free (rgba);
  cairo_destroy (cr);
  cairo_surface_destroy (surf);
  return m;
}

/* Paint glyphs [FROM,TO) of S at pen (X,Y) through the per-display glyph
   atlas and the frame's LrgFrameSurface.

   This is NOT installed as a font_driver `.draw' vfunc: ftcrfont_open hardwires
   font->driver to ftcrfont_driver / ftcrhbfont_driver, so a cloned driver that
   overrode only `.draw' would never actually be used.  Instead the lrg RIF
   (lrg_draw_glyph_string) reuses the real ftcrhb/ftcr drivers for font
   discovery, opening, metrics and shaping -- everything except the final blit
   -- and calls THIS function directly for the blit.  Signature still matches
   the font_driver `.draw' contract so the call site reads like pgtk's.  */
int
lrg_font_draw_glyph_string (struct glyph_string *s, int from, int to, int x,
                            int y, bool with_background)
{
  struct frame *f = s->f;
  struct font *font = s->font;
  struct font_info *fi = (struct font_info *) font;
  cairo_scaled_font_t *scaled = fi->cr_scaled_font;
  LrgFrameSurface *surface = FRAME_LRG_SURFACE (f);
  LrgGlyphAtlas *atlas;
  unsigned long fg = s->xgcv.foreground;
  g_autoptr(GrlColor) fgc = NULL;
  int i;

  /* s->char2b is NULL for glyphless glyph strings: the display engine never
     allocates it for them.  Those must be drawn by lrg_draw_glyphless_glyph_string,
     never routed here -- but guard anyway so a stray caller can't NULL-deref.  */
  if (surface == NULL || scaled == NULL || s->char2b == NULL)
    return 0;

  atlas = lrg_frame_glyph_atlas (f);
  fgc = grl_color_new (LRG_RED (fg), LRG_GREEN (fg), LRG_BLUE (fg), 255);

  if (with_background)
    {
      unsigned long bg = s->xgcv.background;
      g_autoptr(GrlColor) bgc =
        grl_color_new (LRG_RED (bg), LRG_GREEN (bg), LRG_BLUE (bg), 255);
      int fh = FONT_HEIGHT (font);
      lrg_frame_surface_fill_rect (surface, x, y - FONT_BASE (font),
                                   s->width, fh, bgc);
    }

  for (i = from; i < to; i++)
    {
      unsigned code = s->char2b[i];
      LrgGlyphKey *key = lrg_glyph_key_new ((guint64) (uintptr_t) font, code, 0);
      LrgGlyphMetrics *m = lrg_glyph_atlas_lookup (atlas, key);

      if (m == NULL)
        m = lrg_font_bake (atlas, scaled, code, key);

      if (m != NULL)
        {
          lrg_frame_surface_draw_glyph (surface, atlas, key,
                                        (gfloat) x, (gfloat) y, fgc);
          x += lrg_glyph_metrics_get_advance (m);
        }

      lrg_glyph_key_free (key);
    }

  return to - from;
}

/* Register the font drivers used by lrg frames.  We use the stock Cairo
   FreeType/HarfBuzz drivers UNCHANGED (so font discovery, matching, opening,
   metrics and shaping behave exactly as under pgtk -- a cloned driver got the
   font family AND size wrong, and could not redirect `.draw' anyway because
   ftcrfont_open hardwires font->driver).  The blit is redirected at the RIF
   level instead (see lrg_font_draw_glyph_string / lrg_draw_glyph_string).

   Order mirrors pgtk (ftcr first, then ftcrhb) so the resulting font-backend
   list is (ftcrhb ftcr) -- HarfBuzz preferred.  */
void
lrg_register_font_drivers (struct frame *f)
{
  register_font_driver (&ftcrfont_driver, f);
  register_font_driver (&ftcrhbfont_driver, f);
}

void
syms_of_cmacs_lrgfont (void)
{
}

#endif /* HAVE_CMACS_LRGTERM */
