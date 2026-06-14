/* cmacs-lrgterm.c --- output_lrg terminal + redisplay interface.

Copyright (C) 2026 Zach Podbielniak

This file is part of cmacs, a fork of GNU Emacs.

SPDX-License-Identifier: AGPL-3.0-or-later

The terminal hooks + redisplay_interface for the independent libregnum/raylib
display backend.  All drawing is delegated to the frame's LrgFrameSurface
(libregnum), so this file is Emacs-shaped glue with no raylib calls.

Rendering model (FBO-bug-safe; see lrgterm-backend memory): raylib's default
framebuffer is double-buffered, so incremental redisplay can't accumulate
there.  Instead the RIF draw hooks are NO-OPS during normal redisplay (gated
by `lrg_drawing'); the whole frame is repainted from its current glyph matrix
in lrg_frame_up_to_date via expose_frame, between begin_frame/end_frame.  With
the glyph atlas this full repaint is GPU-cheap and sidesteps both the
textured-quad-in-FBO bug and the double-buffer staleness problem.  */

#include <config.h>

#ifdef HAVE_CMACS_LRGTERM

#include <libregnum.h>
#include <cairo.h>		/* image pixels live in img->cr_data (a cairo pattern) */
#include <math.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/timerfd.h>

#include "lisp.h"
#include "blockinput.h"
#include "frame.h"
#include "window.h"
#include "termchar.h"
#include "termhooks.h"
#include "keyboard.h"
#include "buffer.h"
#include "dispextern.h"
#include "font.h"
#include "fontset.h"
#include "character.h"
#include "coding.h"
#include "cmacs-lrgterm.h"

#ifdef HAVE_CMACS_LIBREGNUM
/* For compositing cmacs-libregnum 3D buffers (editor/gnuseye/CAD/STL) into
   the lrg frame -- raylib-free C view APIs.  */
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"
#endif

struct lrg_display_info *lrg_display_list;
int lrg_requested_render_mode = -1;

/* True only while lrg_present_frame is repainting the frame; the RIF draw
   hooks no-op otherwise (see the rendering-model note above).  */
static bool lrg_drawing;

/* Per-image-surface cache key: the GrlTexture we build for an image is stashed
   as cairo user-data on its image surface, so it is unref'd automatically when
   the surface (img->cr_data) is destroyed (image cleared / reloaded) -- no
   separate table, no leak.  */
static const cairo_user_data_key_t lrg_image_texture_key;

static struct redisplay_interface lrg_redisplay_interface;

/* ------------------------------------------------------------ helpers --- */

static GrlColor *
lrg_color (unsigned long pixel)
{
  return grl_color_new ((pixel >> 16) & 0xff, (pixel >> 8) & 0xff,
                        pixel & 0xff, 255);
}

/* Like lrg_color, but with an explicit alpha (0-255).  */
static GrlColor *
lrg_color_a (unsigned long pixel, guint8 a)
{
  return grl_color_new ((pixel >> 16) & 0xff, (pixel >> 8) & 0xff,
                        pixel & 0xff, a);
}

/* Alpha (0-255) for BACKGROUND fills on frame F.  255 (opaque) normally;
   scaled by the frame's `alpha-background' (the Emacs 29 translucent-background
   feature) when it is < 1.0.  Foreground -- text, cursor, borders, fringe
   bitmaps -- always stays opaque, so only the background lets the desktop
   through.  */
static guint8
lrg_bg_alpha (struct frame *f)
{
  double a = f->alpha_background;
  if (a >= 1.0)
    return 255;
  if (a <= 0.0)
    return 0;
  return (guint8) (a * 255.0 + 0.5);
}

/* GL blend factors/equation for a "replace" (source) blend.  The lrg layer
   does not pull in <GL/gl.h> or raylib's rlgl.h, so spell the stable GL enum
   values inline: GL_ZERO, GL_ONE, GL_FUNC_ADD.  */
enum { LRG_GL_ZERO = 0, LRG_GL_ONE = 1, LRG_GL_FUNC_ADD = 0x8006 };

/* Fill a BACKGROUND rectangle on F honoring `alpha-background'.  On an opaque
   frame this is a plain fill.  On a translucent frame it REPLACES the
   destination pixels with (COLOR, alpha) -- mirroring pgtk's
   CAIRO_OPERATOR_SOURCE -- so each face background composites directly over the
   desktop rather than blending over the already-translucent frame background
   (which would tint non-default backgrounds).  Foreground is drawn afterwards
   with the normal alpha-over blend, so text stays crisp and opaque.  */
static void
lrg_fill_bg (struct frame *f, LrgFrameSurface *surf,
             int x, int y, int width, int height, unsigned long color)
{
  guint8 a = lrg_bg_alpha (f);
  g_autoptr (GrlColor) c = lrg_color_a (color, a);

  if (a == 255)
    {
      lrg_frame_surface_fill_rect (surf, x, y, width, height, c);
      return;
    }

  grl_rlgl_set_blend_factors (LRG_GL_ONE, LRG_GL_ZERO, LRG_GL_FUNC_ADD);
  grl_rlgl_set_blend_mode (GRL_BLEND_CUSTOM);
  lrg_frame_surface_fill_rect (surf, x, y, width, height, c);
  grl_rlgl_set_blend_mode (GRL_BLEND_ALPHA);
}

/* ----------------------------------------------------- RIF: drawing ----- */

static void
lrg_flush_display (struct frame *f)
{
  /* Presentation happens in lrg_frame_up_to_date; nothing to flush here.  */
  (void) f;
}

static void
lrg_clear_frame_area (struct frame *f, int x, int y, int width, int height)
{
  LrgFrameSurface *s = FRAME_LRG_SURFACE (f);

  if (!lrg_drawing || s == NULL)
    return;

  lrg_fill_bg (f, s, x, y, width, height, FRAME_LRG_BACKGROUND_COLOR (f));
}

static void
lrg_clear_under_internal_border (struct frame *f)
{
  int b = FRAME_INTERNAL_BORDER_WIDTH (f);

  if (!lrg_drawing || b <= 0)
    return;

  {
    int w = FRAME_PIXEL_WIDTH (f);
    int h = FRAME_PIXEL_HEIGHT (f);

    lrg_clear_frame_area (f, 0, 0, w, b);
    lrg_clear_frame_area (f, 0, 0, b, h);
    lrg_clear_frame_area (f, 0, h - b, w, b);
    lrg_clear_frame_area (f, w - b, 0, b, h);
  }
}

/* Fill a glyph string's background.  */
static void
lrg_draw_glyph_string_bg (struct glyph_string *s)
{
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (s->f);
  int box = max (s->face->box_vertical_line_width, 0);

  lrg_fill_bg (s->f, surf, s->x, s->y + box, s->background_width,
               s->height - 2 * box, s->xgcv.background);
}

/* Return (building + caching on first use) a GrlTexture for IMG.  In this
   Cairo build the displayable pixels are NOT in img->pixmap (which is freed
   after loading) but in img->cr_data, a cairo_pattern_t wrapping an image
   surface (CAIRO_FORMAT_ARGB32 premultiplied B,G,R,A, or RGB24).  Convert to
   straight RGBA and upload to a texture, which we stash as cairo user-data on
   the surface so it dies with the image.  NULL if there is no usable surface.  */
static GrlTexture *
lrg_texture_for_image (struct image *img)
{
  cairo_pattern_t *pat = (cairo_pattern_t *) img->cr_data;
  cairo_surface_t *surface = NULL;
  cairo_format_t fmt;
  const unsigned char *cdata;
  GrlTexture *tex;
  int w, h, stride, x, y;
  guint8 *rgba;

  if (pat == NULL
      || cairo_pattern_get_surface (pat, &surface) != CAIRO_STATUS_SUCCESS
      || cairo_surface_get_type (surface) != CAIRO_SURFACE_TYPE_IMAGE)
    return NULL;

  tex = cairo_surface_get_user_data (surface, &lrg_image_texture_key);
  if (tex != NULL)
    return tex;

  cairo_surface_flush (surface);
  cdata = cairo_image_surface_get_data (surface);
  w = cairo_image_surface_get_width (surface);
  h = cairo_image_surface_get_height (surface);
  stride = cairo_image_surface_get_stride (surface);
  fmt = cairo_image_surface_get_format (surface);
  if (cdata == NULL || w <= 0 || h <= 0)
    return NULL;

  rgba = g_malloc ((gsize) w * h * 4);
  for (y = 0; y < h; y++)
    {
      const unsigned char *row = cdata + (gsize) y * stride;
      for (x = 0; x < w; x++)
        {
          const unsigned char *src = row + (gsize) x * 4; /* B,G,R,A premult */
          guint8 *o = rgba + ((gsize) y * w + x) * 4;
          guint8 a = (fmt == CAIRO_FORMAT_ARGB32) ? src[3] : 255;
          /* cairo stores premultiplied B,G,R,A (native-endian ARGB32); the
             atlas/texture format is straight R8G8B8A8, so swap B<->R and
             un-premultiply.  */
          if (a == 0)
            o[0] = o[1] = o[2] = o[3] = 0;
          else if (a == 255)
            { o[0] = src[2]; o[1] = src[1]; o[2] = src[0]; o[3] = 255; }
          else
            {
              o[0] = (guint8) (src[2] * 255 / a);   /* un-premultiply R */
              o[1] = (guint8) (src[1] * 255 / a);   /* G */
              o[2] = (guint8) (src[0] * 255 / a);   /* B */
              o[3] = a;
            }
        }
    }
  {
    g_autoptr (GrlColor) clear = grl_color_new (0, 0, 0, 0);
    g_autoptr (GrlImage) gi = grl_image_new_color (w, h, clear);
    g_autoptr (GrlRectangle) rect = grl_rectangle_new (0, 0, w, h);
    grl_image_set_format (gi, GRL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    tex = grl_texture_new_from_image (gi);
    if (tex != NULL)
      grl_texture_update_rec (tex, rect, rgba);
  }
  g_free (rgba);
  if (tex != NULL)
    cairo_surface_set_user_data (surface, &lrg_image_texture_key, tex,
                                 (cairo_destroy_func_t) g_object_unref);
  return tex;
}

/* Underline / overline / strike-through / box decorations, drawn AFTER the
   glyphs (mirrors pgtk_draw_glyph_string's tail).  Without these, links,
   isearch, boxed mode-line/button faces etc. render as plain text.  */
static void
lrg_draw_glyph_string_decorations (struct glyph_string *s)
{
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (s->f);
  struct face *face = s->face;
  int x = s->x;
  int w = s->width;

  if (face == NULL)
    return;

  if (face->underline != FACE_NO_UNDERLINE)
    {
      unsigned long c = face->underline_defaulted_p
                        ? s->xgcv.foreground : face->underline_color;
      g_autoptr (GrlColor) col = lrg_color (c);
      int thickness = (s->font && s->font->underline_thickness > 0)
                      ? s->font->underline_thickness : 1;
      int pos;
      if (face->underline_at_descent_line_p)
        pos = (s->y + s->height) - face->underline_pixels_above_descent_line
              - thickness;
      else if (s->font && s->font->underline_position > 0)
        pos = s->ybase + s->font->underline_position;
      else
        pos = s->ybase + 1;
      if (pos + thickness > s->y + s->height)
        pos = s->y + s->height - thickness;
      lrg_frame_surface_fill_rect (surf, x, pos, w, thickness, col);
      if (face->underline == FACE_UNDERLINE_DOUBLE_LINE
          && pos + 2 * thickness + 1 <= s->y + s->height)
        lrg_frame_surface_fill_rect (surf, x, pos + thickness + 1, w,
                                     thickness, col);
    }

  if (face->overline_p)
    {
      unsigned long c = face->overline_color_defaulted_p
                        ? s->xgcv.foreground : face->overline_color;
      g_autoptr (GrlColor) col = lrg_color (c);
      lrg_frame_surface_fill_rect (surf, x, s->y, w, 1, col);
    }

  if (face->strike_through_p)
    {
      unsigned long c = face->strike_through_color_defaulted_p
                        ? s->xgcv.foreground : face->strike_through_color;
      g_autoptr (GrlColor) col = lrg_color (c);
      lrg_frame_surface_fill_rect (surf, x, s->y + s->height / 2, w, 1, col);
    }

  if (face->box != FACE_NO_BOX)
    {
      unsigned long c = face->box_color_defaulted_p
                        ? s->xgcv.foreground : face->box_color;
      g_autoptr (GrlColor) col = lrg_color (c);
      int hw = max (face->box_horizontal_line_width, 1);
      int vw = max (face->box_vertical_line_width, 1);
      lrg_frame_surface_fill_rect (surf, x, s->y, w, hw, col);
      lrg_frame_surface_fill_rect (surf, x, s->y + s->height - hw, w, hw, col);
      if (s->first_glyph->left_box_line_p)
        lrg_frame_surface_fill_rect (surf, x, s->y, vw, s->height, col);
      if (s->nchars > 0 && s->first_glyph[s->nchars - 1].right_box_line_p)
        lrg_frame_surface_fill_rect (surf, x + w - vw, s->y, vw, s->height, col);
    }
}

static void
lrg_draw_glyph_string (struct glyph_string *s)
{
  if (!lrg_drawing || FRAME_LRG_SURFACE (s->f) == NULL)
    return;

  /* Make the per-string GC values the font driver / bg fill read.  */
  s->xgcv.foreground = s->face->foreground;
  s->xgcv.background = s->face->background;
  if (s->hl == DRAW_CURSOR)
    {
      s->xgcv.foreground = FRAME_LRG_BACKGROUND_COLOR (s->f);
      s->xgcv.background = FRAME_LRG_OUTPUT (s->f)->cursor_color;
    }

  switch (s->first_glyph->type)
    {
    case CHAR_GLYPH:
    case COMPOSITE_GLYPH:
    case GLYPHLESS_GLYPH:
      if (s->for_overlaps
          || (s->background_width > 0 && !s->background_filled_p))
        {
          lrg_draw_glyph_string_bg (s);
          s->background_filled_p = true;
        }
      /* Reuse the stock ftcrhb/ftcr font object (open/metrics/shape) but
         redirect the actual blit to our atlas-backed surface painter.  We do
         NOT call s->font->driver->draw: that is ftcrfont_draw, which paints
         onto a Cairo context lrg frames do not have.  */
      if (s->font != NULL)
        lrg_font_draw_glyph_string (s, 0, s->nchars, s->x, s->ybase, false);
      lrg_draw_glyph_string_decorations (s);
      break;

    case STRETCH_GLYPH:
      {
        LrgFrameSurface *surf = FRAME_LRG_SURFACE (s->f);
        /* A stretch glyph under the cursor is opaque (it IS the cursor);
           otherwise it is a background and honors alpha-background, as in
           pgtk_clear_glyph_string_rect.  */
        if (s->hl == DRAW_CURSOR)
          {
            g_autoptr (GrlColor) bg = lrg_color (s->face->background);
            lrg_frame_surface_fill_rect (surf, s->x, s->y,
                                         s->background_width, s->height, bg);
          }
        else
          lrg_fill_bg (s->f, surf, s->x, s->y,
                       s->background_width, s->height, s->face->background);
      }
      break;

    case IMAGE_GLYPH:
      {
        LrgFrameSurface *surf = FRAME_LRG_SURFACE (s->f);
        struct image *img = s->img;
        GrlTexture *tex;

        if (img == NULL)
          break;
        /* Fill the face background first (transparent images show it).  */
        if (s->background_width > 0 && !s->background_filled_p)
          {
            lrg_draw_glyph_string_bg (s);
            s->background_filled_p = true;
          }
        tex = lrg_texture_for_image (img);
        if (tex != NULL)
          {
            g_autoptr (GrlColor) white = grl_color_new (255, 255, 255, 255);
            /* The texture is the NATIVE pixmap size; :scale/:width/:height are
               applied by Emacs as a transform, so img->width/height (and the
               slice) are in DISPLAYED coords.  Map the slice back to pixmap
               (source) coords; draw at the displayed size.  */
            int tw = grl_texture_get_width (tex);
            int th = grl_texture_get_height (tex);
            double sxr = (img->width > 0 ? (double) tw / img->width : 1.0);
            double syr = (img->height > 0 ? (double) th / img->height : 1.0);
            g_autoptr (GrlRectangle) src =
              grl_rectangle_new ((gfloat) (s->slice.x * sxr),
                                 (gfloat) (s->slice.y * syr),
                                 (gfloat) (s->slice.width * sxr),
                                 (gfloat) (s->slice.height * syr));
            int x = s->x;
            int y = s->ybase - image_ascent (img, s->face, &s->slice);
            if (s->slice.x == 0)
              x += img->hmargin;
            if (s->slice.y == 0)
              y += img->vmargin;
            lrg_frame_surface_draw_texture_region
              (surf, tex, src, (gfloat) x, (gfloat) y,
               (gfloat) s->slice.width, (gfloat) s->slice.height, white);
          }
      }
      break;

    case XWIDGET_GLYPH:
    default:
      /* xwidgets: deferred (Phase 8).  */
      break;
    }
}

/* RIF define_frame_cursor: set the frame's mouse-pointer shape.  Mouse
   cursor shapes are a later refinement (Phase 6), but this MUST be non-NULL:
   note_mouse_highlight -> define_frame_cursor1 calls it unconditionally and a
   NULL hook segfaults.  */
static void
lrg_define_frame_cursor (struct frame *f, Emacs_Cursor cursor)
{
  FRAME_LRG_OUTPUT (f)->current_cursor = cursor;
}

static void
lrg_draw_window_cursor (struct window *w, struct glyph_row *glyph_row,
                        int x, int y, enum text_cursor_kinds cursor_type,
                        int cursor_width, bool on_p, bool active_p)
{
  struct frame *f = XFRAME (w->frame);
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (f);
  int fx, fy, h, cw;
  g_autoptr(GrlColor) cc = NULL;

  (void) active_p;

  /* Drawn only during a full expose (lrg_present_frame); cursor blink / direct
     toggles reach the screen via the buffer-flipping-unblocked present.  */
  if (!lrg_drawing || surf == NULL || !on_p)
    return;

  fx = WINDOW_TEXT_TO_FRAME_PIXEL_X (w, x);
  fy = WINDOW_TO_FRAME_PIXEL_Y (w, y);
  h = glyph_row->height;
  cw = cursor_width > 0 ? cursor_width : 2;
  cc = lrg_color (FRAME_LRG_OUTPUT (f)->cursor_color);

  switch (cursor_type)
    {
    case HOLLOW_BOX_CURSOR:
      lrg_frame_surface_draw_rect_outline (surf, fx, fy,
                                           glyph_row->glyphs[TEXT_AREA]
                                           ? glyph_row->glyphs[TEXT_AREA]->pixel_width
                                           : FRAME_COLUMN_WIDTH (f),
                                           h, 1.0f, cc);
      break;
    case BAR_CURSOR:
      lrg_frame_surface_fill_rect (surf, fx, fy, cw, h, cc);
      break;
    case HBAR_CURSOR:
      lrg_frame_surface_fill_rect (surf, fx, fy + h - cw,
                                   FRAME_COLUMN_WIDTH (f), cw, cc);
      break;
    case FILLED_BOX_CURSOR:
      /* Re-draw the glyph under the cursor with the DRAW_CURSOR highlight
         (fills the cell in cursor_color and paints the glyph in the cursor
         foreground).  expose_frame draws glyphs NORMALLY, so this is needed
         for the focused (solid) block cursor to appear at all.  */
      draw_phys_cursor_glyph (w, glyph_row, DRAW_CURSOR);
      break;
    case NO_CURSOR:
    default:
      break;
    }
}

static void
lrg_draw_vertical_window_border (struct window *w, int x, int y0, int y1)
{
  struct frame *f = XFRAME (w->frame);
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (f);
  struct face *face;
  g_autoptr(GrlColor) c = NULL;

  if (!lrg_drawing || surf == NULL)
    return;

  face = FACE_FROM_ID_OR_NULL (f, VERTICAL_BORDER_FACE_ID);
  c = lrg_color (face ? face->foreground : FRAME_LRG_FOREGROUND_COLOR (f));
  lrg_frame_surface_fill_rect (surf, x, y0, 1, y1 - y0, c);
}

static void
lrg_draw_window_divider (struct window *w, int x0, int x1, int y0, int y1)
{
  struct frame *f = XFRAME (w->frame);
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (f);
  struct face *face;
  g_autoptr(GrlColor) c = NULL;

  if (!lrg_drawing || surf == NULL)
    return;

  face = FACE_FROM_ID_OR_NULL (f, WINDOW_DIVIDER_FACE_ID);
  c = lrg_color (face ? face->foreground : FRAME_LRG_FOREGROUND_COLOR (f));
  lrg_frame_surface_fill_rect (surf, x0, y0, x1 - x0, y1 - y0, c);
}

static void
lrg_draw_fringe_bitmap (struct window *w, struct glyph_row *row,
                        struct draw_fringe_bitmap_params *p)
{
  struct frame *f = XFRAME (w->frame);
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (f);
  struct face *face;

  if (!lrg_drawing || surf == NULL)
    return;

  /* Background.  */
  face = p->face;
  if (p->bx >= 0 && !p->overlay_p)
    lrg_fill_bg (f, surf, p->bx, p->by, p->nx, p->ny,
                 face ? face->background : FRAME_LRG_BACKGROUND_COLOR (f));

  /* Foreground bitmap (continuation / truncation / overlay arrows, etc.):
     paint each set bit as a 1px rect in the fringe foreground (cursor colour
     for a cursor fringe).  Bits are MSB-first within p->wd, as in w32term.  */
  if (p->which != 0 && p->bits != NULL)
    {
      unsigned long fgpix = p->cursor_p
        ? FRAME_LRG_OUTPUT (f)->cursor_color
        : (face ? face->foreground : FRAME_LRG_FOREGROUND_COLOR (f));
      g_autoptr (GrlColor) fg = lrg_color (fgpix);
      int i, j;
      for (i = 0; i < p->h; i++)
        {
          unsigned int bits = p->bits[i];
          for (j = 0; j < p->wd; j++)
            if (bits & (1u << (p->wd - 1 - j)))
              lrg_frame_surface_fill_rect (surf, p->x + j, p->y + i, 1, 1, fg);
        }
    }
  (void) row;
}

static void
lrg_after_update_window_line (struct window *w, struct glyph_row *desired_row)
{
  (void) w;
  desired_row->redraw_fringe_bitmaps_p = true;
}

static void
lrg_scroll_run (struct window *w, struct run *run)
{
  /* Full-frame repaint model: nothing to copy; the next frame_up_to_date
     repaints from the matrix.  */
  (void) w;
  (void) run;
}

/* ------------------------------------------------- terminal: update ----- */

static void
lrg_update_begin (struct frame *f)
{
  (void) f;
}

static void
lrg_update_end (struct frame *f)
{
  MOUSE_HL_INFO (f)->mouse_face_defer = false;
}

#ifdef HAVE_CMACS_LIBREGNUM
/* Composite cmacs-libregnum 3D buffers into the lrg frame.  Mirrors the pgtk
   overlay (cmacs_libregnum_overlay_paint) but draws the view's FBO colour
   texture through the LrgFrameSurface instead of a cairo blit.  The view's
   GLib idle renders the scene INTO its FBO (the GL context is current on the
   main thread); here, during the present, we just blit it.  */
static void
lrg_paint_libregnum_window (struct frame *f, LrgFrameSurface *surf, Lisp_Object w)
{
  while (!NILP (w) && WINDOWP (w))
    {
      struct window *win = XWINDOW (w);
      Lisp_Object contents = win->contents;

      if (WINDOWP (contents))
        lrg_paint_libregnum_window (f, surf, contents);
      else if (BUFFERP (contents))
        {
          CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (contents);
          CmacsLibregnumRenderCtx *ctx
            = v ? cmacs_libregnum_view_get_render_ctx (v) : NULL;
          GrlTexture *tex
            = ctx ? cmacs_libregnum_render_ctx_get_fbo_texture (ctx) : NULL;
          int vw = 0, vh = 0;

          if (v != NULL)
            cmacs_libregnum_view_get_size (v, &vw, &vh);
          if (tex != NULL && vw > 0 && vh > 0)
            {
              int px = WINDOW_LEFT_PIXEL_EDGE (win);
              int py = WINDOW_TOP_PIXEL_EDGE  (win);
              int pw = WINDOW_PIXEL_WIDTH     (win);
              int ph = WINDOW_PIXEL_HEIGHT    (win);
              /* The FBO colour texture is bottom-up (GL origin lower-left);
                 a negative source height flips it (raylib DrawTexturePro
                 convention), matching the pgtk cairo Y-flip.  The dst rect
                 scales the view to the window body.  */
              g_autoptr (GrlRectangle) src
                = grl_rectangle_new (0.0f, (gfloat) vh, (gfloat) vw,
                                     -(gfloat) vh);
              g_autoptr (GrlColor) white = grl_color_new (255, 255, 255, 255);

              lrg_frame_surface_draw_texture_region
                (surf, tex, src, (gfloat) px, (gfloat) py,
                 (gfloat) pw, (gfloat) ph, white);
              cmacs_libregnum_view_mark_painted (v);
            }
        }
      w = win->next;
    }
}

static void
lrg_paint_libregnum_views (struct frame *f)
{
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (f);

  if (surf != NULL)
    lrg_paint_libregnum_window (f, surf, f->root_window);
}
#endif /* HAVE_CMACS_LIBREGNUM */

/* Present the whole frame: clear + repaint every visible glyph from the
   current matrix (immune to the FBO bug -- default framebuffer only) + swap.

   This is lrg's ONLY way to put pixels on screen: because it presents via a
   double-buffered swap (no retained surface; the rlgl FBO bug rules that out),
   it cannot honour Emacs's INCREMENTAL RIF draws, so those are gated to no-ops
   (the `lrg_drawing' flag) and the whole frame is repainted here instead.
   Consequently this must run after EVERY redisplay, including the optimised
   single-line self-insert / cursor-only paths that DON'T call
   frame_up_to_date -- hence it is driven from update_window_end (per window)
   and the standalone cursor hook as well as frame_up_to_date.  */
static void
lrg_present_frame (struct frame *f)
{
  LrgFrameSurface *surf;

  if (!FRAME_LRG_P (f))
    return;
  surf = FRAME_LRG_SURFACE (f);
  /* Re-entrancy guard only: callers (frame_up_to_date /
     buffer_flipping_unblocked) ensure flips are not blocked.  */
  if (surf == NULL || lrg_drawing)
    return;

  block_input ();
  {
    /* Clear to the frame background at alpha-background, so the uncovered
       backdrop is translucent (lets the desktop through) when requested and
       fully opaque otherwise.  */
    g_autoptr(GrlColor) bg = lrg_color_a (FRAME_LRG_BACKGROUND_COLOR (f),
                                          lrg_bg_alpha (f));

    lrg_frame_surface_begin_frame (surf);
    lrg_frame_surface_clear (surf, bg);

    lrg_drawing = true;
    expose_frame (f, 0, 0, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f));
    lrg_drawing = false;

#ifdef HAVE_CMACS_LIBREGNUM
    /* Composite any cmacs-libregnum 3D buffers (editor/gnuseye/CAD/STL) on
       top of the text, into their windows' rects.  */
    lrg_paint_libregnum_views (f);
#endif

    lrg_frame_surface_end_frame (surf);
  }
  unblock_input ();
}

static void
lrg_frame_up_to_date (struct frame *f)
{
  /* During a redisplay, buffer flips are blocked (so the frame is not shown
     half-updated); defer the present to lrg_buffer_flipping_unblocked, which
     runs when the redisplay completes.  Present immediately only if we are
     somehow called outside a blocked region.  */
  if (!buffer_flipping_blocked_p ())
    lrg_present_frame (f);
}

/* terminal->buffer_flipping_unblocked_hook: called once per redisplay, AFTER
   the update completes and buffer flips are unblocked.  This is lrg's real
   present point -- frame_up_to_date and the RIF draw hooks all run while flips
   are blocked, so THIS is where typed text, cursor blink and every other
   redisplay actually reaches the screen.  Mirrors pgtk_buffer_flipping_
   unblocked_hook.  */
static void
lrg_buffer_flipping_unblocked (struct frame *f)
{
  lrg_present_frame (f);
}

static void
lrg_clear_frame (struct frame *f)
{
  /* The next frame_up_to_date clears + repaints; nothing immediate.  */
  (void) f;
}

/* ------------------------------------------------- terminal: misc ------- */

static void
lrg_ring_bell (struct frame *f)
{
  (void) f;
}

/* ---- Phase 4: input/event loop ---------------------------------------

   GLFW (raylib's desktop backend) requires that input be polled on the
   main thread, so lrg does NOT use a separate input thread.  Instead
   lrg_term_init arms a timerfd (~60 Hz) registered with
   add_keyboard_wait_descriptor, so Emacs's pselect wakes periodically and
   calls this read_socket_hook.  Here we poll the window ONCE
   (grl_window_poll_events == raylib PollInputEvents -- the single poll
   point, see lrg_2d_surface_end_frame) and translate the queued input into
   struct input_events.

   Keyboard: printable text comes from the Unicode char queue
   (grl_input_get_char_pressed), which already honours layout/shift/dead
   keys; control/meta combinations and non-character keys are read from the
   key-press state and mapped to ASCII control chars or X keysyms
   (NON_ASCII_KEYSTROKE_EVENT, which Emacs maps to `left', `f1', ... via the
   0xff00 lispy_function_keys table -- correct because cmacs is a pgtk/X
   build).  */

/* GrlKey -> X keysym for non-character keys (NON_ASCII_KEYSTROKE_EVENT).  */
struct lrg_keymap { int grl; int keysym; };
static const struct lrg_keymap lrg_function_keys[] =
  {
    { GRL_KEY_ENTER,     0xff0d }, /* Return    */
    { GRL_KEY_KP_ENTER,  0xff8d }, /* KP_Enter  */
    { GRL_KEY_TAB,       0xff09 }, /* Tab       */
    { GRL_KEY_BACKSPACE, 0xff08 }, /* BackSpace */
    { GRL_KEY_ESCAPE,    0xff1b }, /* Escape    */
    { GRL_KEY_INSERT,    0xff63 }, /* Insert    */
    { GRL_KEY_DELETE,    0xffff }, /* Delete    */
    { GRL_KEY_RIGHT,     0xff53 }, /* Right     */
    { GRL_KEY_LEFT,      0xff51 }, /* Left      */
    { GRL_KEY_DOWN,      0xff54 }, /* Down      */
    { GRL_KEY_UP,        0xff52 }, /* Up        */
    { GRL_KEY_PAGE_UP,   0xff55 }, /* Prior     */
    { GRL_KEY_PAGE_DOWN, 0xff56 }, /* Next      */
    { GRL_KEY_HOME,      0xff50 }, /* Home      */
    { GRL_KEY_END,       0xff57 }, /* End       */
  };

/* X keysym for the non-character GrlKey K (for NON_ASCII_KEYSTROKE_EVENT),
   or 0 when K is not a mapped function key (e.g. a printable or modifier).  */
static int
lrg_keysym_for (GrlKey k)
{
  size_t i;

  for (i = 0; i < countof (lrg_function_keys); i++)
    if (lrg_function_keys[i].grl == (int) k)
      return lrg_function_keys[i].keysym;
  return 0;
}

/* Return the first live output_lrg frame, or NULL (v1 has at most one).  */
static struct frame *
lrg_any_frame (void)
{
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);
      if (FRAME_LIVE_P (f) && FRAME_LRG_P (f))
        return f;
    }
  return NULL;
}

/* TRUE when an output_lrg frame is live -- i.e. the raylib window + GL
   context already exist and belong to this backend.  The cmacs-libregnum
   subsystem links this (weakly) to detect that it must REUSE this context
   for its FBO rendering rather than opening a second raylib window (which
   would deadlock -- raylib is one-window-per-process).  */
bool
cmacs_lrgterm_active_p (void)
{
  return lrg_any_frame () != NULL;
}

/* Present the active lrg frame NOW (re-expose the glyph matrix + blit the
   libregnum FBOs).  cmacs-libregnum links this weakly so a camera drag/zoom --
   which re-renders a view's FBO but changes no text, hence triggers no Emacs
   redisplay -- is shown immediately instead of only on the next redisplay
   (e.g. after a click).  Safe from a GLib idle: the GL context is current on
   the main thread, flips are not blocked while waiting for input, and
   lrg_present_frame's own re-entrancy guard covers any overlap.  */
void
cmacs_lrgterm_present_now (void)
{
  struct frame *f = lrg_any_frame ();
  if (f != NULL)
    lrg_present_frame (f);
}

/* Current Emacs modifier bits from the physically held modifier keys.  */
static int
lrg_event_modifiers (void)
{
  int m = 0;
  if (grl_input_is_key_down (GRL_KEY_LEFT_CONTROL)
      || grl_input_is_key_down (GRL_KEY_RIGHT_CONTROL))
    m |= ctrl_modifier;
  if (grl_input_is_key_down (GRL_KEY_LEFT_ALT)
      || grl_input_is_key_down (GRL_KEY_RIGHT_ALT))
    m |= meta_modifier;
  if (grl_input_is_key_down (GRL_KEY_LEFT_SUPER)
      || grl_input_is_key_down (GRL_KEY_RIGHT_SUPER))
    m |= super_modifier;
  return m;
}

/* True if a control or meta modifier is currently held (suppresses the
   character-queue path so e.g. C-a is read as a key, not a literal char).  */
static bool
lrg_ctrl_or_meta_down (void)
{
  return grl_input_is_key_down (GRL_KEY_LEFT_CONTROL)
         || grl_input_is_key_down (GRL_KEY_RIGHT_CONTROL)
         || grl_input_is_key_down (GRL_KEY_LEFT_ALT)
         || grl_input_is_key_down (GRL_KEY_RIGHT_ALT);
}

/* Store a translated key/mouse event; returns 1 (events stored counter).  */
static int
lrg_store (struct frame *f, struct input_event *hold_quit,
           struct input_event *ie)
{
  XSETFRAME (ie->frame_or_window, f);
  kbd_buffer_store_event_hold (ie, hold_quit);
  return 1;
}

/* Emit a character keystroke CP (already layout/shift-resolved) on F.  */
static int
lrg_store_char (struct frame *f, struct input_event *hold_quit, int cp,
                int modifiers)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = (cp < 128 ? ASCII_KEYSTROKE_EVENT
                      : MULTIBYTE_CHAR_KEYSTROKE_EVENT);
  ie.code = cp;
  ie.modifiers = modifiers;
  ie.timestamp = 0;
  return lrg_store (f, hold_quit, &ie);
}

static int
lrg_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  struct lrg_display_info *dpyinfo = terminal->display_info.lrg;
  struct frame *f;
  GrlWindow *win;
  int count = 0;
  int mods;
  int cp;

  /* Drain the wakeup timerfd so pselect does not spin on it.  */
  if (dpyinfo != NULL && dpyinfo->connection >= 0)
    {
      uint64_t expirations;
      ssize_t n;
      do
        n = read (dpyinfo->connection, &expirations, sizeof expirations);
      while (n < 0 && errno == EINTR);
    }

  f = lrg_any_frame ();
  if (f == NULL)
    return 0;
  win = lrg_window_of_frame (f);
  if (win == NULL)
    return 0;

  block_input ();
  grl_window_poll_events (win);          /* the single poll point */
  unblock_input ();

  /* Close button (ESC-as-exit was disabled at window creation).  */
  if (grl_window_should_close (win))
    {
      struct input_event ie;
      EVENT_INIT (ie);
      ie.kind = DELETE_WINDOW_EVENT;
      grl_window_set_should_close (win, FALSE);
      count += lrg_store (f, hold_quit, &ie);
    }

  /* Window resize -> re-fit the Emacs frame to the new pixel size.  */
  if (grl_window_is_resized (win))
    {
      int w = grl_window_get_width (win);
      int h = grl_window_get_height (win);
      if (w > 0 && h > 0
          && (w != FRAME_PIXEL_WIDTH (f) || h != FRAME_PIXEL_HEIGHT (f)))
        {
          block_input ();
          change_frame_size (f, w, h, false, true, false);
          unblock_input ();
          SET_FRAME_GARBAGED (f);
        }
    }

  /* Focus changes (cursor solid vs hollow).  */
  {
    bool focused = grl_window_is_focused (win);
    if (focused != (dpyinfo->pgtk.x_focus_frame != NULL))
      {
        struct input_event ie;
        EVENT_INIT (ie);
        if (focused)
          {
            dpyinfo->pgtk.x_focus_frame = f;
            dpyinfo->pgtk.highlight_frame = f;
            ie.kind = FOCUS_IN_EVENT;
          }
        else
          {
            dpyinfo->pgtk.x_focus_frame = NULL;
            dpyinfo->pgtk.highlight_frame = NULL;
            ie.kind = FOCUS_OUT_EVENT;
          }
        count += lrg_store (f, hold_quit, &ie);
      }
  }

  mods = lrg_event_modifiers ();

  /* Keyboard: drain the key-press QUEUE in press order (robust -- it never
     misses or repeats a fast tap the way a per-frame state scan does, which
     is what made ESC/hjkl flaky under Evil).  For each pressed key:
       - a mapped non-character key (ESC, arrows, Tab, RET, ...) becomes a
         NON_ASCII_KEYSTROKE_EVENT carrying its X keysym + modifiers;
       - a printable key with Ctrl/Meta held becomes a char event with
         modifiers (GLFW emits no char callback for those, so we synthesize
         it from the US-ASCII keycode, lower-casing letters so C-A == C-a);
       - a printable key with no Ctrl/Meta consumes the next Unicode char
         from the char queue (which already encodes layout + shift) -- pulling
         it HERE keeps it correctly interleaved with any function keys pressed
         in the same poll (e.g. ESC then x stays ESC, x).  */
  {
    bool ctrlmeta = lrg_ctrl_or_meta_down ();
    GrlKey k;

    while ((k = grl_input_get_key_pressed ()) != GRL_KEY_NULL)
      {
        int keysym = lrg_keysym_for (k);

        if (keysym != 0)
          {
            struct input_event ie;
            EVENT_INIT (ie);
            ie.kind = NON_ASCII_KEYSTROKE_EVENT;
            ie.code = keysym;
            ie.modifiers = mods;
            count += lrg_store (f, hold_quit, &ie);
          }
        else if (k >= GRL_KEY_SPACE && k <= GRL_KEY_GRAVE)
          {
            if (ctrlmeta)
              {
                int code = (int) k;
                if (code >= GRL_KEY_A && code <= GRL_KEY_Z)
                  code += 32;          /* 'A'..'Z' -> 'a'..'z' */
                count += lrg_store_char (f, hold_quit, code, mods);
              }
            else if ((cp = grl_input_get_char_pressed ()) != 0)
              count += lrg_store_char (f, hold_quit, cp,
                                       mods & ~(ctrl_modifier | meta_modifier));
          }
        /* else: a modifier key, or an unmapped function/keypad key -> skip.  */
      }

    /* Emit any chars the key loop did not pair with a printable key -- IME
       commits, pasted text, multi-char dead-key sequences -- in order.  */
    if (!ctrlmeta)
      while ((cp = grl_input_get_char_pressed ()) != 0)
        count += lrg_store_char (f, hold_quit, cp,
                                 mods & ~(ctrl_modifier | meta_modifier));
  }

  /* Mouse motion.  First offer it to a libregnum view (camera orbit/pan
     while a drag is active); only when not consumed do we update the
     mouse-face highlight (hover on buttons, links, ...).  Mirrors pgtk's
     motion_notify_event short-circuit.  Only when the pointer moved.  */
  {
    static int last_mx = -1, last_my = -1;
    int mx = grl_input_get_mouse_x ();
    int my = grl_input_get_mouse_y ();
    if ((mx != last_mx || my != last_my) && grl_window_is_focused (win))
      {
        last_mx = mx;
        last_my = my;
#ifdef HAVE_CMACS_LIBREGNUM
        if (!cmacs_libregnum_handle_motion (f, mx, my))
#endif
          {
            block_input ();
            note_mouse_highlight (f, mx, my);
            unblock_input ();
          }
      }
  }

  /* Mouse buttons: press/release -> MOUSE_CLICK_EVENT (Emacs forms the
     click/drag).  raylib button order L,R,M -> Emacs 0,1,2.  */
  {
    static const int rl_to_emacs_button[3] = { 0, 2, 1 };
#ifdef HAVE_CMACS_LIBREGNUM
    /* raylib L,R,M -> X11/GDK 1,3,2, which cmacs_libregnum_handle_button
       expects (it maps those internally).  */
    static const int rl_to_x11_button[3] = { 1, 3, 2 };
#endif
    int b;
    int mx = grl_input_get_mouse_x ();
    int my = grl_input_get_mouse_y ();
    for (b = 0; b < 3; b++)
      {
        bool pressed = grl_input_is_mouse_button_pressed ((GrlMouseButton) b);
        bool released = grl_input_is_mouse_button_released ((GrlMouseButton) b);
        if (!pressed && !released)
          continue;
#ifdef HAVE_CMACS_LIBREGNUM
        /* Offer the transition to a libregnum view first (pick/orbit/pan/
           right-click menu).  When it consumes the event (pointer over a
           view), suppress the corresponding Emacs click so the 3D view isn't
           also treated as a text click.  Press and release are distinct. */
        {
          int x11b = rl_to_x11_button[b];
          if (pressed && cmacs_libregnum_handle_button (f, x11b, 1, mx, my))
            pressed = false;
          if (released && cmacs_libregnum_handle_button (f, x11b, 0, mx, my))
            released = false;
          if (!pressed && !released)
            continue;
        }
#endif
        {
          struct input_event ie;
          EVENT_INIT (ie);
          ie.kind = MOUSE_CLICK_EVENT;
          ie.code = rl_to_emacs_button[b];
          ie.modifiers = mods | (pressed ? down_modifier : up_modifier);
          XSETINT (ie.x, mx);
          XSETINT (ie.y, my);
          ie.timestamp = 0;
          count += lrg_store (f, hold_quit, &ie);
        }
      }
  }

  /* Mouse wheel -> libregnum camera zoom when the pointer is over a view;
     otherwise a normal Emacs WHEEL_EVENT so buffers scroll under --lrg
     (the wheel was previously unhandled here entirely).  */
  {
    float wheel = grl_input_get_mouse_wheel_move ();
    if (wheel != 0.0f && grl_window_is_focused (win))
      {
        int mx = grl_input_get_mouse_x ();
        int my = grl_input_get_mouse_y ();
        bool consumed = false;
#ifdef HAVE_CMACS_LIBREGNUM
        /* pgtk passes GDK smooth-scroll dy (wheel-up is negative); raylib's
           wheel-up is positive, so negate to match the zoom direction. */
        consumed = cmacs_libregnum_handle_scroll (f, 0.0, -(double) wheel,
                                                  mx, my);
#endif
        if (!consumed)
          {
            struct input_event ie;
            EVENT_INIT (ie);
            ie.kind = WHEEL_EVENT;
            ie.modifiers = mods | (wheel > 0 ? up_modifier : down_modifier);
            XSETINT (ie.x, mx);
            XSETINT (ie.y, my);
            XSETFRAME (ie.frame_or_window, f);
            ie.arg = Qnil;
            ie.timestamp = 0;
            count += lrg_store (f, hold_quit, &ie);
          }
      }
  }

  return count;
}

static void
lrg_mouse_position (struct frame **fp, int insist, Lisp_Object *bar_window,
                    enum scroll_bar_part *part, Lisp_Object *x, Lisp_Object *y,
                    Time *timestamp)
{
  struct frame *f = lrg_any_frame ();

  (void) insist;
  *bar_window = Qnil;
  *part = scroll_bar_above_handle;
  *timestamp = 0;

  if (f != NULL && lrg_window_of_frame (f) != NULL)
    {
      *fp = f;
      XSETINT (*x, grl_input_get_mouse_x ());
      XSETINT (*y, grl_input_get_mouse_y ());
    }
  else
    {
      *x = Qnil;
      *y = Qnil;
    }
}

static void
lrg_frame_rehighlight_hook (struct frame *f)
{
  (void) f;
}

static bool
lrg_defined_color (struct frame *f, const char *color_name,
                   Emacs_Color *color_def, bool alloc, bool make_index)
{
  unsigned r, g, b;

  (void) f;
  (void) alloc;
  (void) make_index;

  if (color_name == NULL)
    return false;

  /* #RRGGBB / #RGB.  */
  if (color_name[0] == '#')
    {
      size_t len = strlen (color_name + 1);
      if (len == 6 && sscanf (color_name + 1, "%2x%2x%2x", &r, &g, &b) == 3)
        ;
      else if (len == 3 && sscanf (color_name + 1, "%1x%1x%1x", &r, &g, &b) == 3)
        {
          r *= 17; g *= 17; b *= 17;
        }
      else
        return false;
    }
  else
    {
      /* Resolve named colours (Firebrick, Blue1, grey75, "dark slate
         blue", ...) through pango's X11 rgb.txt colour table (pango.h is in
         scope via libregnum.h).  Emacs's default faces use the full X11 name
         set, so the previous tiny hand-list rendered every font-lock face
         black.  */
      PangoColor pc;
      if (!pango_color_parse (&pc, color_name))
        return false;
      r = pc.red >> 8;
      g = pc.green >> 8;
      b = pc.blue >> 8;
    }

  color_def->red = r * 257;
  color_def->green = g * 257;
  color_def->blue = b * 257;
  color_def->pixel = (r << 16) | (g << 8) | b;
  return true;
}

static void
lrg_query_colors (struct frame *f, Emacs_Color *colors, int ncolors)
{
  int i;
  (void) f;
  for (i = 0; i < ncolors; i++)
    {
      unsigned long p = colors[i].pixel;
      colors[i].red = ((p >> 16) & 0xff) * 257;
      colors[i].green = ((p >> 8) & 0xff) * 257;
      colors[i].blue = (p & 0xff) * 257;
    }
}

static void
lrg_query_frame_background_color (struct frame *f, Emacs_Color *bgcolor)
{
  bgcolor->pixel = FRAME_LRG_BACKGROUND_COLOR (f);
  lrg_query_colors (f, bgcolor, 1);
}

static void
lrg_set_window_size (struct frame *f, bool change_gravity, int width, int height)
{
  /* This is set_window_size_hook: our job is to resize the OS window to the
     requested pixel size.  The caller (adjust_frame_size) already updated the
     Emacs frame's own size fields -- calling change_frame_size here re-enters
     the frame-resize machinery and corrupts f->new_width/new_height (it left
     the frame stuck at a degenerate ~80px size).  For lrg there are no window
     decorations or out-of-text scroll bars, so the requested text size IS the
     OS window size.  */
  GrlWindow *win = lrg_window_of_frame (f);
  (void) change_gravity;
  block_input ();
  if (win != NULL)
    grl_window_set_size (win, width, height);
  SET_FRAME_GARBAGED (f);
  unblock_input ();
}

static Lisp_Object
lrg_new_font (struct frame *f, Lisp_Object font_object, int fontset)
{
  struct font *font = XFONT_OBJECT (font_object);
  int unit, font_ascent, font_descent;

  if (fontset < 0)
    fontset = fontset_from_font (font_object);
  FRAME_FONTSET (f) = fontset;
  if (FRAME_FONT (f) == font)
    return font_object;

  FRAME_LRG_OUTPUT (f)->font = font;
  FRAME_LRG_OUTPUT (f)->baseline_offset = font->baseline_offset;

  FRAME_COLUMN_WIDTH (f) = font->average_width;
  get_font_ascent_descent (font, &font_ascent, &font_descent);
  FRAME_LINE_HEIGHT (f) = font_ascent + font_descent;

  unit = FRAME_COLUMN_WIDTH (f);
  if (FRAME_LRG_DISPLAY_INFO (f)->pgtk.smallest_font_height == 0
      || FRAME_LINE_HEIGHT (f) < FRAME_LRG_DISPLAY_INFO (f)->pgtk.smallest_font_height)
    FRAME_LRG_DISPLAY_INFO (f)->pgtk.smallest_font_height = FRAME_LINE_HEIGHT (f);
  if (FRAME_LRG_DISPLAY_INFO (f)->pgtk.smallest_char_width == 0
      || unit < FRAME_LRG_DISPLAY_INFO (f)->pgtk.smallest_char_width)
    FRAME_LRG_DISPLAY_INFO (f)->pgtk.smallest_char_width = unit;

  if (FRAME_LRG_SURFACE (f) != NULL)
    adjust_frame_size (f, FRAME_COLS (f) * FRAME_COLUMN_WIDTH (f),
                       FRAME_LINES (f) * FRAME_LINE_HEIGHT (f), 3, false,
                       Qfont);
  return font_object;
}

static const char *
lrg_get_string_resource (void *rdb, const char *name, const char *class)
{
  (void) rdb;
  (void) name;
  (void) class;
  return NULL;
}

static void
lrg_implicitly_set_name (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  GrlWindow *win = lrg_window_of_frame (f);
  (void) oldval;
  if (win != NULL && STRINGP (arg))
    grl_window_set_title (win, SSDATA (arg));
}

static void
lrg_implicitly_set_name_hook (struct frame *f, Lisp_Object arg,
                              Lisp_Object oldval)
{
  lrg_implicitly_set_name (f, arg, oldval);
}

static void
lrg_make_frame_visible_invisible (struct frame *f, bool visible)
{
  SET_FRAME_VISIBLE (f, visible);
}

static void
lrg_set_scroll_bar_default_width (struct frame *f)
{
  int unit = FRAME_COLUMN_WIDTH (f);
  FRAME_CONFIG_SCROLL_BAR_WIDTH (f) = 16;
  FRAME_CONFIG_SCROLL_BAR_COLS (f) = (16 + unit - 1) / unit;
}

static void
lrg_set_scroll_bar_default_height (struct frame *f)
{
  int height = FRAME_LINE_HEIGHT (f);
  FRAME_CONFIG_SCROLL_BAR_HEIGHT (f) = 16;
  FRAME_CONFIG_SCROLL_BAR_LINES (f) = (16 + height - 1) / height;
}

static void
lrg_condemn_scroll_bars (struct frame *f) { (void) f; }
static void
lrg_redeem_scroll_bar (struct window *w) { (void) w; }
static void
lrg_judge_scroll_bars (struct frame *f) { (void) f; }
static void
lrg_set_vertical_scroll_bar (struct window *w, int portion, int whole, int pos)
{ (void) w; (void) portion; (void) whole; (void) pos; }
static void
lrg_set_horizontal_scroll_bar (struct window *w, int portion, int whole, int pos)
{ (void) w; (void) portion; (void) whole; (void) pos; }

static Lisp_Object
lrg_get_focus_frame (struct frame *f)
{
  struct frame *focus = FRAME_LRG_DISPLAY_INFO (f)->pgtk.x_focus_frame;
  Lisp_Object lisp_focus;
  if (focus == NULL)
    return Qnil;
  XSETFRAME (lisp_focus, focus);
  return lisp_focus;
}

static void
lrg_focus_frame (struct frame *f, bool noactivate)
{
  GrlWindow *win = lrg_window_of_frame (f);
  (void) noactivate;
  if (win != NULL)
    grl_window_focus (win);
}

/* --------------------------------------------------- frame deletion ----- */

void
lrg_free_frame_resources (struct frame *f)
{
  block_input ();
  lrg_window_destroy (f);
  if (FRAME_LRG_OUTPUT (f) != NULL)
    {
      xfree (FRAME_LRG_OUTPUT (f));
      FRAME_LRG_OUTPUT (f) = NULL;
    }
  unblock_input ();
}

static void
lrg_delete_frame (struct frame *f)
{
  lrg_free_frame_resources (f);
}

void
lrg_delete_terminal (struct terminal *terminal)
{
  struct lrg_display_info *dpyinfo = terminal->display_info.lrg;
  struct lrg_display_info **tail;

  if (!terminal->name)
    return;

  block_input ();
  for (tail = &lrg_display_list; *tail; tail = &(*tail)->next)
    if (*tail == dpyinfo)
      {
        *tail = dpyinfo->next;
        break;
      }
  if (dpyinfo->glyph_atlas != NULL)
    g_clear_object (&dpyinfo->glyph_atlas);
  unblock_input ();
}

/* RIF menu_show_hook.  GUI popup menus are deferred (Phase 7); this MUST be
   non-NULL because menu.c calls it directly for window-system frames (a NULL
   hook crashes).  Returning no selection is safe; keyboard menu access is via
   M-x tmm-menubar / F10 (tmm builds menus in Lisp + the minibuffer, bypassing
   this hook).  Dialogs route to the minibuffer (use-dialog-box is nil for lrg,
   and popup_dialog_hook stays NULL -- menu.c guards that one).  */
static Lisp_Object
lrg_menu_show (struct frame *f, int x, int y, int menuflags,
               Lisp_Object title, const char **error_name)
{
  (void) f; (void) x; (void) y; (void) menuflags; (void) title;
  *error_name = NULL;
  return Qnil;
}

/* terminal->free_pixmap.  In this Cairo build Emacs_Pixmap is the minimal
   Emacs_Pix_Container ({width,height,data,...}) that image.c fills in the
   USE_CAIRO path -- frame-independent, so this matches pgtk_free_pixmap.  It
   MUST be non-NULL: image.c's image_clear_image_1 calls it unconditionally
   when freeing a loaded image, and a NULL hook crashes (e.g. the Doom
   dashboard / any inline image).  */
static void
lrg_free_pixmap (struct frame *f, Emacs_Pixmap pixmap)
{
  (void) f;
  if (pixmap)
    {
      xfree (pixmap->data);
      xfree (pixmap);
    }
}

/* ------------------------------------------------- terminal create ----- */

struct terminal *
lrg_create_terminal (struct lrg_display_info *dpyinfo)
{
  struct terminal *terminal;

  terminal = create_terminal (output_lrg, &lrg_redisplay_interface);
  terminal->display_info.lrg = dpyinfo;
  dpyinfo->pgtk.terminal = terminal;

  terminal->clear_frame_hook = lrg_clear_frame;
  terminal->ring_bell_hook = lrg_ring_bell;
  terminal->update_begin_hook = lrg_update_begin;
  terminal->update_end_hook = lrg_update_end;
  terminal->read_socket_hook = lrg_read_socket;
  terminal->frame_up_to_date_hook = lrg_frame_up_to_date;
  terminal->mouse_position_hook = lrg_mouse_position;
  terminal->frame_rehighlight_hook = lrg_frame_rehighlight_hook;
  terminal->frame_visible_invisible_hook = lrg_make_frame_visible_invisible;
  terminal->set_vertical_scroll_bar_hook = lrg_set_vertical_scroll_bar;
  terminal->set_horizontal_scroll_bar_hook = lrg_set_horizontal_scroll_bar;
  terminal->condemn_scroll_bars_hook = lrg_condemn_scroll_bars;
  terminal->redeem_scroll_bar_hook = lrg_redeem_scroll_bar;
  terminal->judge_scroll_bars_hook = lrg_judge_scroll_bars;
  terminal->get_string_resource_hook = lrg_get_string_resource;
  terminal->delete_frame_hook = lrg_delete_frame;
  terminal->delete_terminal_hook = lrg_delete_terminal;
  terminal->query_frame_background_color = lrg_query_frame_background_color;
  terminal->defined_color_hook = lrg_defined_color;
  terminal->query_colors = lrg_query_colors;
  terminal->set_new_font_hook = lrg_new_font;
  terminal->implicit_set_name_hook = lrg_implicitly_set_name_hook;
  terminal->set_scroll_bar_default_width_hook = lrg_set_scroll_bar_default_width;
  terminal->set_scroll_bar_default_height_hook
    = lrg_set_scroll_bar_default_height;
  terminal->set_window_size_hook = lrg_set_window_size;
  terminal->get_focus_frame = lrg_get_focus_frame;
  terminal->focus_frame_hook = lrg_focus_frame;
  terminal->buffer_flipping_unblocked_hook = lrg_buffer_flipping_unblocked;
  terminal->free_pixmap = lrg_free_pixmap;
  terminal->menu_show_hook = lrg_menu_show;
  /* popup_dialog_hook left NULL (menu.c guards it); use-dialog-box is nil for
     lrg so dialogs go to the minibuffer.  */

  return terminal;
}

struct lrg_display_info *
lrg_term_init (Lisp_Object display_name, char *resource_name)
{
  struct lrg_display_info *dpyinfo;
  struct terminal *terminal;

  (void) resource_name;
  block_input ();

  dpyinfo = xzalloc (sizeof *dpyinfo);
  terminal = lrg_create_terminal (dpyinfo);

  dpyinfo->pgtk.resx = 96.0;
  dpyinfo->pgtk.resy = 96.0;
  dpyinfo->pgtk.reference_count = 0;
  dpyinfo->pgtk.n_planes = 24;
  dpyinfo->pgtk.color_p = 1;
  dpyinfo->pgtk.name_list_element = Fcons (display_name, Qnil);

  terminal->name = xlispstrdup (display_name);
  terminal->kboard = allocate_kboard (Qlrg);
  /* Lrg terminals never get a kboard of their own back; share input.  */
  terminal->kboard->reference_count++;

  dpyinfo->next = lrg_display_list;
  lrg_display_list = dpyinfo;

  /* Phase 4 event loop: a ~60 Hz timerfd is our pselect wakeup source.
     GLFW input must be polled on the main thread, so rather than an input
     thread + self-pipe we let this fd make Emacs's pselect return
     periodically and call lrg_read_socket, which polls the window once.  */
  dpyinfo->connection = timerfd_create (CLOCK_MONOTONIC,
                                        TFD_NONBLOCK | TFD_CLOEXEC);
  if (dpyinfo->connection >= 0)
    {
      struct itimerspec its;
      its.it_interval.tv_sec = 0;
      its.it_interval.tv_nsec = 16 * 1000 * 1000;   /* 16 ms */
      its.it_value = its.it_interval;
      timerfd_settime (dpyinfo->connection, 0, &its, NULL);
      add_keyboard_wait_descriptor (dpyinfo->connection);
    }

  /* The fringe bitmaps are shared; init once.  */
  gui_init_fringe (terminal->rif);

  unblock_input ();
  return dpyinfo;
}

struct lrg_display_info *
check_lrg_display_info (Lisp_Object object)
{
  (void) object;
  if (lrg_display_list == NULL)
    error ("No lrg display available");
  return lrg_display_list;
}

DEFUN ("lrg-capture-screen", Flrg_capture_screen, Slrg_capture_screen, 1, 2, 0,
       doc: /* Capture FRAME's libregnum window to FILENAME (a PNG/BMP/etc.).
The image format is chosen from FILENAME's extension.  FRAME defaults to the
selected frame and must be an lrg (libregnum) frame.  Returns FILENAME.

This repaints the frame from its current glyph matrix into the back buffer,
reads the pixels back, and writes them out -- it does not depend on any
external screen capture, so it works as a deterministic rendering oracle for
tests and as the basis of the lrgterm_dump_screen MCP tool.  */)
  (Lisp_Object filename, Lisp_Object frame)
{
  struct frame *f = decode_window_system_frame (frame);
  LrgFrameSurface *surf;
  Lisp_Object encoded;
  bool ok;

  CHECK_STRING (filename);
  if (!FRAME_LRG_P (f))
    error ("Not an lrg frame");
  surf = FRAME_LRG_SURFACE (f);
  if (surf == NULL)
    error ("lrg frame has no surface");

  encoded = ENCODE_FILE (filename);

  block_input ();
  {
    g_autoptr (GrlColor) bg = lrg_color (FRAME_LRG_BACKGROUND_COLOR (f));
    g_autoptr (GrlImage) img = NULL;
    int pass;

    /* raylib batches draw commands and only flushes them to the framebuffer
       at end_frame (EndDrawing), which then swaps buffers.  grl_image_new_
       from_screen reads the BACK buffer via glReadPixels.  To read fully
       rendered+flushed content we render the (identical) frame TWICE: after
       the second end_frame's swap, the back buffer holds the first frame's
       flushed pixels.  (A one-shot read before end_frame sees only the clear
       colour because the glyph quads are still in the unflushed batch.)  */
    for (pass = 0; pass < 2; pass++)
      {
        lrg_frame_surface_begin_frame (surf);
        lrg_frame_surface_clear (surf, bg);

        lrg_drawing = true;
        expose_frame (f, 0, 0, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f));
        lrg_drawing = false;

#ifdef HAVE_CMACS_LIBREGNUM
        lrg_paint_libregnum_views (f);
#endif

        lrg_frame_surface_end_frame (surf);
      }

    img = grl_image_new_from_screen ();
    ok = img != NULL && grl_image_export (img, SSDATA (encoded));
  }
  unblock_input ();

  if (!ok)
    error ("Failed to capture lrg screen to %s", SDATA (filename));
  return filename;
}

DEFUN ("lrg-display-pixel-size", Flrg_display_pixel_size, Slrg_display_pixel_size,
       0, 0, 0,
       doc: /* Return (WIDTH . HEIGHT), in pixels, of the lrg display's current
monitor, or nil if no lrg window is open.  Used by the lrg branches of
`display-pixel-width' / `display-pixel-height' / `display-monitor-attributes-list'
in frame.el (the generic x-display-* primitives do not handle lrg frames).  */)
  (void)
{
  struct frame *f = lrg_any_frame ();
  GrlWindow *win = (f != NULL) ? lrg_window_of_frame (f) : NULL;
  int mon, w, h;

  if (win == NULL)
    return Qnil;
  mon = grl_window_get_current_monitor (win);
  w = grl_window_get_monitor_width (win, mon);
  h = grl_window_get_monitor_height (win, mon);
  if (w <= 0 || h <= 0)
    return Qnil;
  return Fcons (make_fixnum (w), make_fixnum (h));
}

DEFUN ("lrg-set-clipboard", Flrg_set_clipboard, Slrg_set_clipboard, 1, 1, 0,
       doc: /* Put TEXT (a string) on the lrg window's system clipboard.
Returns TEXT.  Used by the lrg gui-backend-set-selection method for CLIPBOARD.  */)
  (Lisp_Object text)
{
  struct frame *f = lrg_any_frame ();
  GrlWindow *win = (f != NULL) ? lrg_window_of_frame (f) : NULL;

  CHECK_STRING (text);
  if (win != NULL)
    {
      Lisp_Object enc = ENCODE_UTF_8 (text);
      block_input ();
      grl_window_set_clipboard_text (win, SSDATA (enc));
      unblock_input ();
    }
  return text;
}

DEFUN ("lrg-get-clipboard", Flrg_get_clipboard, Slrg_get_clipboard, 0, 0, 0,
       doc: /* Return the lrg window's system clipboard text as a string, or nil.
Used by the lrg gui-backend-get-selection method for CLIPBOARD.  */)
  (void)
{
  struct frame *f = lrg_any_frame ();
  GrlWindow *win = (f != NULL) ? lrg_window_of_frame (f) : NULL;
  Lisp_Object result = Qnil;
  gchar *text;

  if (win == NULL)
    return Qnil;
  block_input ();
  text = grl_window_get_clipboard_text (win);
  unblock_input ();
  if (text != NULL)
    {
      result = build_string_from_utf8 (text);
      g_free (text);
    }
  return result;
}

/* Frame-parameter handler table, defined in cmacs-lrgfns.c.  Set in the
   static initializer below: it must be wired at link time, NOT at syms/dump
   time, because this struct is C static data that reverts to its initializer
   on every (post-dump) startup.  */
extern frame_parm_handler lrg_frame_parm_handlers[];

/* The RIF is built positionally; unset members are NULL (the generic gui_*
   fallbacks are used where appropriate).  */
static struct redisplay_interface lrg_redisplay_interface =
  {
    lrg_frame_parm_handlers,
    gui_produce_glyphs,
    gui_write_glyphs,
    gui_insert_glyphs,
    gui_clear_end_of_line,
    lrg_scroll_run,
    lrg_after_update_window_line,
    NULL,                                  /* update_window_begin */
    NULL,                                  /* update_window_end */
    lrg_flush_display,
    gui_clear_window_mouse_face,
    gui_get_glyph_overhangs,
    gui_fix_overlapping_area,
    lrg_draw_fringe_bitmap,
    NULL,                                  /* define_fringe_bitmap */
    NULL,                                  /* destroy_fringe_bitmap */
    NULL,                                  /* compute_glyph_string_overhangs */
    lrg_draw_glyph_string,
    lrg_define_frame_cursor,
    lrg_clear_frame_area,
    lrg_clear_under_internal_border,
    lrg_draw_window_cursor,
    lrg_draw_vertical_window_border,
    lrg_draw_window_divider,
    NULL,                                  /* shift_glyphs_for_insert */
    NULL,                                  /* show_hourglass */
    NULL,                                  /* hide_hourglass */
    lrg_default_font_parameter,
  };

/* Forward decls from lrgfont.c / lrgfns.c.  */
extern void syms_of_cmacs_lrgfont (void);
extern void syms_of_cmacs_lrgfns (void);

void
syms_of_cmacs_lrgterm (void)
{
  DEFSYM (Qlrg, "lrg");
  Fprovide (Qlrg, Qnil);
  defsubr (&Slrg_capture_screen);
  defsubr (&Slrg_display_pixel_size);
  defsubr (&Slrg_set_clipboard);
  defsubr (&Slrg_get_clipboard);
  syms_of_cmacs_lrgfont ();
  syms_of_cmacs_lrgfns ();
}

void
init_cmacs_lrgterm (void)
{
}

/* GC: mark the Lisp objects living in each lrg display's embedded
   pgtk_display_info (the font-list cache cons), which is in C heap and thus
   not otherwise reachable.  Called from alloc.c's mark phase.  */
void
mark_lrgterm (void)
{
  struct lrg_display_info *dpyinfo;

  for (dpyinfo = lrg_display_list; dpyinfo != NULL; dpyinfo = dpyinfo->next)
    mark_object (dpyinfo->pgtk.name_list_element);
}

#endif /* HAVE_CMACS_LRGTERM */
