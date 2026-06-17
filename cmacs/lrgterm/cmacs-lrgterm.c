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
#include <cairo-ft.h>		/* pulls FcPattern/FT so ftfont.h's font_info is usable */
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
#include "ftfont.h"		/* struct font_info + cr_scaled_font (menu text) */
#include "fontset.h"
#include "character.h"
#include "coding.h"
#include "cmacs-lrgterm.h"

#ifdef HAVE_CMACS_LIBREGNUM
/* For compositing cmacs-libregnum 3D buffers (editor/gnuseye/CAD/STL) into
   the lrg frame -- raylib-free C view APIs.  */
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"
#ifdef HAVE_CMACS_GSURF_LRG
#include "cmacs-gsurf.h"   /* compositing + input for gsurf-lrg web buffers */
#endif
#endif

struct lrg_display_info *lrg_display_list;
int lrg_requested_render_mode = -1;
const char *lrg_requested_3d_spec = NULL;

/* Buffer whose libregnum 3D view (e.g. the gnuseye globe) is shown on the
   cockpit environment's back wall, or nil.  Set by `cmacs-lrg-3d-set-wall'.  */
static Lisp_Object lrg_cockpit_wall_buffer;

/* True only while lrg_present_frame is repainting the frame; the RIF draw
   hooks no-op otherwise (see the rendering-model note above).  */
static bool lrg_drawing;

/* When true, lrg_present_frame returns without drawing/swapping.  Set around an
   off-screen workspace render (cmacs-lrg-3d-begin/end-offscreen): the embedder
   installs a non-current workspace's window-config and (redisplay)s it to build
   its glyph matrices; that redisplay's present must NOT reach the screen (it would
   show -- and capture into the live panels -- the wrong workspace).  Only the
   explicit cmacs-lrg-3d-render-into-panel render runs during the suppressed
   window, and it bypasses this flag.  */
static bool lrg_present_suppressed;

/* Workspace panels (the 3D workspace ring) get keys distinct from any Emacs
   window key, which is a `struct window *' cast to guint64 (a canonical
   user-space pointer, so bit 63 is always clear).  We therefore set bit 63 and
   pack a small workspace index in the low bits.  The Elisp <-> C boundary only
   ever passes the small index (a Lisp fixnum); the full guint64 key never leaves
   C, avoiding Lisp bignums for high-bit values.  */
#define LRG_WS_PANEL_BIT     (((guint64) 1) << 63)
#define LRG_WS_KEY(idx)      (LRG_WS_PANEL_BIT | (guint64) (idx))
#define LRG_WS_IS_KEY(k)     (((k) & LRG_WS_PANEL_BIT) != 0)
#define LRG_WS_KEY_INDEX(k)  ((int) ((k) & ~LRG_WS_PANEL_BIT))

/* Workspace index a Ctrl+double-left-click selected (a workspace panel), or -1.
   Set from lrg_read_socket; consumed by cmacs-lrg-3d-take-pending-workspace from
   the workspace switcher's command-loop timer -- the switch (+workspace-switch)
   thus runs in the command loop, never as Lisp called from the input path.  */
static int lrg_pending_ws_select = -1;

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

#ifdef HAVE_CMACS_GSURF_LRG
  /* A gsurf web page fills the window body, so the Emacs cursor over it is just
     noise (and would otherwise show despite cursor-type nil, since evil's state
     cursor overrides it).  Suppress it unless cmacs-gsurf-lrg-hide-cursor.  */
  if (cmacs_gsurf_lrg_hide_cursor_p (w->contents))
    return;
#endif

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
#ifdef HAVE_CMACS_GSURF_LRG
          /* Not a libregnum 3D buffer -- try a gsurf-lrg web page.  Its
             readback is top-down (cairo origin top-left), so no Y-flip. */
          if (tex == NULL)
            {
              int px = WINDOW_LEFT_PIXEL_EDGE (win);
              int py = WINDOW_TOP_PIXEL_EDGE  (win);
              int pw = WINDOW_PIXEL_WIDTH      (win);
              int ph = WINDOW_PIXEL_HEIGHT     (win);
              int gw = 0, gh = 0;
              GrlTexture *gtex
                = cmacs_gsurf_lrg_texture_for_window (contents, pw, ph,
                                                      &gw, &gh);
              if (gtex != NULL && gw > 0 && gh > 0)
                {
                  g_autoptr (GrlRectangle) gsrc
                    = grl_rectangle_new (0.0f, 0.0f, (gfloat) gw, (gfloat) gh);
                  g_autoptr (GrlColor) gwhite
                    = grl_color_new (255, 255, 255, 255);
                  lrg_frame_surface_draw_texture_region
                    (surf, gtex, gsrc, (gfloat) px, (gfloat) py,
                     (gfloat) pw, (gfloat) ph, gwhite);
                }
            }
#endif
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

/* Feed `lrg_cockpit_wall_buffer's libregnum view FBO texture to the cockpit
   environment's back wall (the "ambient cockpit" dashboards / gnuseye globe).
   No-op unless SURF is a 3D surface in the cockpit environment.  */
static void
lrg_feed_cockpit_wall (struct frame *f, LrgFrameSurface *surf)
{
  Lrg3DSurface *s3;
  LrgPanelEnvironment *env;
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  GrlTexture *tex;

  (void) f;

  if (surf == NULL || !LRG_IS_3D_SURFACE (surf))
    return;
  s3 = LRG_3D_SURFACE (surf);
  env = lrg_3d_surface_get_environment (s3);
  if (env == NULL || !LRG_IS_ENVIRONMENT_COCKPIT (env))
    return;

  if (!BUFFERP (lrg_cockpit_wall_buffer)
      || !BUFFER_LIVE_P (XBUFFER (lrg_cockpit_wall_buffer)))
    {
      lrg_environment_cockpit_set_back_texture (LRG_ENVIRONMENT_COCKPIT (env),
                                                NULL);
      return;
    }

  v = cmacs_libregnum_view_for_buffer (lrg_cockpit_wall_buffer);
  ctx = v != NULL ? cmacs_libregnum_view_get_render_ctx (v) : NULL;
  tex = ctx != NULL ? cmacs_libregnum_render_ctx_get_fbo_texture (ctx) : NULL;
  if (tex != NULL)
    {
      lrg_environment_cockpit_set_back_texture (LRG_ENVIRONMENT_COCKPIT (env),
                                                tex);
      cmacs_libregnum_view_mark_painted (v);
    }
}
#endif /* HAVE_CMACS_LIBREGNUM */

/* ===================================================== in-engine popup menu ==
   A GTK-like right-click context menu drawn by the lrg backend itself (no
   minibuffer / tmm), WITH cascading fly-out submenus.  `cmacs-libregnum-popup
   -menu' (Elisp) flattens an Emacs menu into a nested item tree and calls
   `lrg-popup-menu', which runs a modal loop -- poll input + present each frame,
   like x-popup-menu's own modal loop -- and returns the chosen leaf's index.
   The open menu is a STACK of panels (the root plus each open submenu);
   lrg_present_frame draws `lrg_active_menu' over the text + libregnum views.
   lrg_font_bake (declared in cmacs-lrgterm.h) renders label glyphs.

   Item-tree node (built from the Lisp list by lrg_menu_build_items):
     nil               => separator row
     (LABEL . INDEX)   => leaf; choosing it returns INDEX (a fixnum)
     (LABEL)/(LABEL.nil)=> disabled leaf
     (LABEL ITEM...)   => submenu whose children are ITEM...  */

typedef struct LrgMenuItem
{
  char               *label;      /* NULL => separator row                   */
  bool                enabled;
  int                 index;      /* leaf: value to return; -1 otherwise     */
  struct LrgMenuItem *children;   /* submenu items (owned); NULL for a leaf  */
  int                 n_children;
} LrgMenuItem;

typedef struct
{
  LrgMenuItem *items;    /* NOT owned: points into the tree                  */
  int          n;
  int          x, y, w, h;
  int          hovered;  /* index into items, or -1                          */
} LrgMenuPanel;

#define LRG_MENU_MAX_DEPTH 8

typedef struct
{
  LrgMenuItem  *root;      /* owned item tree                                */
  int           root_n;
  LrgMenuPanel  panel[LRG_MENU_MAX_DEPTH];
  int           depth;     /* open panels (>= 1; panel[0] is the root)       */
  int           item_h, pad_x, pad_y, arrow_w;
} LrgMenuState;

static LrgMenuState *lrg_active_menu;

/* Blend pixel A toward pixel B by T (0..1) at alpha ALPHA -- for the menu
   panel/border/hover tints, derived from the frame fg/bg so the menu matches
   any theme without needing a dedicated face.  */
static GrlColor *
lrg_menu_blend (unsigned long a, unsigned long b, double t, guint8 alpha)
{
  int ar = (a >> 16) & 0xff, ag = (a >> 8) & 0xff, ab = a & 0xff;
  int br = (b >> 16) & 0xff, bg = (b >> 8) & 0xff, bb = b & 0xff;
  return grl_color_new ((guint8) (ar + (br - ar) * t),
                        (guint8) (ag + (bg - ag) * t),
                        (guint8) (ab + (bb - ab) * t), alpha);
}

/* Pixel width of UTF-8 STR in F's default font.  The lrg default editing font
   is monospace, so column-width * char-count is exact enough for menu sizing
   (and avoids baking every glyph just to measure).  */
static int
lrg_menu_text_px (struct frame *f, const char *str)
{
  int n = 0;
  const char *p = str;
  while (p != NULL && *p)
    {
      n++;
      p = g_utf8_next_char (p);
    }
  return n * FRAME_COLUMN_WIDTH (f);
}

/* Draw UTF-8 STR with its top-left at (X, Y_TOP) in F's default font, colour
   FG, through the per-display glyph atlas (same path as buffer text).  */
static void
lrg_menu_draw_text (struct frame *f, int x, int y_top, const char *str,
                    const GrlColor *fg)
{
  struct font *font = FRAME_FONT (f);
  struct font_info *fi = (struct font_info *) font;
  cairo_scaled_font_t *scaled = fi ? fi->cr_scaled_font : NULL;
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (f);
  LrgGlyphAtlas *atlas;
  int y_base = y_top + FONT_BASE (font);
  const char *p = str;

  if (font == NULL || scaled == NULL || surf == NULL || str == NULL)
    return;
  atlas = lrg_frame_glyph_atlas (f);

  while (*p)
    {
      gunichar uc = g_utf8_get_char (p);
      unsigned code = font->driver->encode_char (font, (int) uc);
      LrgGlyphKey *key;
      LrgGlyphMetrics *m;

      p = g_utf8_next_char (p);
      if (code == FONT_INVALID_CODE)
        {
          x += FRAME_COLUMN_WIDTH (f);
          continue;
        }
      key = lrg_glyph_key_new ((guint64) (uintptr_t) font, code, 0);
      m = lrg_glyph_atlas_lookup (atlas, key);
      if (m == NULL)
        m = lrg_font_bake (atlas, scaled, code, key);
      if (m != NULL)
        {
          lrg_frame_surface_draw_glyph (surf, atlas, key,
                                        (gfloat) x, (gfloat) y_base, fg);
          x += lrg_glyph_metrics_get_advance (m);
        }
      else
        x += FRAME_COLUMN_WIDTH (f);
      lrg_glyph_key_free (key);
    }
}

/* Build an LrgMenuItem array from the Lisp item LIST (see the node grammar
   above).  Returns the xmalloc'd array; *N_OUT gets the count.  Recurses for
   submenus.  */
static LrgMenuItem *
lrg_menu_build_items (Lisp_Object list, int *n_out)
{
  int n = 0, i = 0;
  Lisp_Object t;
  LrgMenuItem *arr;

  for (t = list; CONSP (t); t = XCDR (t))
    n++;
  *n_out = n;
  if (n == 0)
    return NULL;
  arr = xnmalloc (n, sizeof *arr);
  for (t = list; CONSP (t); t = XCDR (t), i++)
    {
      Lisp_Object it = XCAR (t);
      arr[i].label = NULL;
      arr[i].enabled = false;
      arr[i].index = -1;
      arr[i].children = NULL;
      arr[i].n_children = 0;
      if (CONSP (it) && STRINGP (XCAR (it)))
        {
          Lisp_Object d = XCDR (it);
          arr[i].label = xstrdup (SSDATA (ENCODE_UTF_8 (XCAR (it))));
          if (FIXNUMP (d))           /* leaf returning that index */
            {
              arr[i].enabled = true;
              arr[i].index = (int) XFIXNUM (d);
            }
          else if (CONSP (d))        /* submenu */
            {
              arr[i].enabled = true;
              arr[i].children = lrg_menu_build_items (d, &arr[i].n_children);
            }
          /* else (d is nil) => disabled leaf */
        }
      /* nil / anything else => separator (label stays NULL) */
    }
  return arr;
}

static void
lrg_menu_free_items (LrgMenuItem *arr, int n)
{
  int i;
  if (arr == NULL)
    return;
  for (i = 0; i < n; i++)
    {
      xfree (arr[i].label);
      lrg_menu_free_items (arr[i].children, arr[i].n_children);
    }
  xfree (arr);
}

/* Per-row height.  Separator rows are half height (just a divider line) so a
   single separator wastes little space.  */
static int
lrg_menu_item_h (LrgMenuState *st, const LrgMenuItem *it)
{
  return it->label == NULL ? (st->item_h + 1) / 2 : st->item_h;
}

/* Y of row ROW relative to the panel top (sum of preceding row heights).  */
static int
lrg_menu_row_top (LrgMenuState *st, LrgMenuPanel *p, int row)
{
  int y = st->pad_y, i;
  for (i = 0; i < row && i < p->n; i++)
    y += lrg_menu_item_h (st, &p->items[i]);
  return y;
}

/* Total panel height for its current items.  */
static int
lrg_menu_total_h (LrgMenuState *st, LrgMenuPanel *p)
{
  int y = 2 * st->pad_y, i;
  for (i = 0; i < p->n; i++)
    y += lrg_menu_item_h (st, &p->items[i]);
  return y;
}

/* Row index at panel-local LOCAL_Y (= mouse_y - panel->y), or -1.  */
static int
lrg_menu_row_at (LrgMenuState *st, LrgMenuPanel *p, int local_y)
{
  int y = st->pad_y, i;
  for (i = 0; i < p->n; i++)
    {
      int h = lrg_menu_item_h (st, &p->items[i]);
      if (local_y >= y && local_y < y + h)
        return i;
      y += h;
    }
  return -1;
}

/* A small right-pointing submenu arrow (a ">") centred in row [Y, Y+H).  */
static void
lrg_menu_draw_arrow (LrgFrameSurface *surf, int x, int y, int h,
                     const GrlColor *c)
{
  int s = h / 5;
  int cy = y + h / 2;
  if (s < 3)
    s = 3;
  lrg_frame_surface_draw_line (surf, x, cy - s, x + s, cy, 1.5f, c);
  lrg_frame_surface_draw_line (surf, x + s, cy, x, cy + s, 1.5f, c);
}

/* Lay PANEL out from its items + ST's metrics, top-left at (X, Y), clamped
   into the frame.  Reserves arrow gutter when any item has a submenu.  */
static void
lrg_menu_panel_layout (struct frame *f, LrgMenuState *st, LrgMenuPanel *p,
                       int x, int y)
{
  int fw = FRAME_PIXEL_WIDTH (f), fh = FRAME_PIXEL_HEIGHT (f);
  int maxw = 0, i, has_sub = 0;

  for (i = 0; i < p->n; i++)
    {
      int wpx;
      if (p->items[i].label == NULL)
        continue;
      wpx = lrg_menu_text_px (f, p->items[i].label);
      if (wpx > maxw)
        maxw = wpx;
      if (p->items[i].children != NULL)
        has_sub = 1;
    }
  p->w = maxw + 2 * st->pad_x + (has_sub ? st->arrow_w : 0);
  p->h = lrg_menu_total_h (st, p);
  p->x = x;
  p->y = y;
  if (p->x + p->w > fw) p->x = fw - p->w;
  if (p->y + p->h > fh) p->y = fh - p->h;
  if (p->x < 0) p->x = 0;
  if (p->y < 0) p->y = 0;
}

/* Open the submenu of item ROW in panel PARENT_DEPTH as the next panel,
   flush to its right (flipping left if it would overflow), and set
   ST->depth to include it.  */
static void
lrg_menu_open_child (struct frame *f, LrgMenuState *st, int parent_depth,
                     int row)
{
  LrgMenuPanel *p = &st->panel[parent_depth];
  LrgMenuPanel *c = &st->panel[parent_depth + 1];
  int fw = FRAME_PIXEL_WIDTH (f);
  int cy = p->y + lrg_menu_row_top (st, p, row);

  c->items = p->items[row].children;
  c->n = p->items[row].n_children;
  c->hovered = -1;
  lrg_menu_panel_layout (f, st, c, p->x + p->w, cy);
  if (p->x + p->w + c->w > fw)            /* would overflow right -> flip */
    lrg_menu_panel_layout (f, st, c, p->x - c->w, cy);
  st->depth = parent_depth + 2;
}

/* Composite the whole open menu (every panel in the stack) onto F's surface,
   after the text + libregnum views.  Called from lrg_present_frame.  */
static void
lrg_menu_render (struct frame *f, LrgFrameSurface *surf, LrgMenuState *st)
{
  unsigned long fg_px = FRAME_LRG_FOREGROUND_COLOR (f);
  unsigned long bg_px = FRAME_LRG_BACKGROUND_COLOR (f);
  g_autoptr(GrlColor) panel  = lrg_menu_blend (bg_px, fg_px, 0.08, 250);
  g_autoptr(GrlColor) border = lrg_menu_blend (bg_px, fg_px, 0.45, 255);
  g_autoptr(GrlColor) hi     = lrg_menu_blend (bg_px, fg_px, 0.28, 255);
  g_autoptr(GrlColor) sep    = lrg_menu_blend (bg_px, fg_px, 0.30, 255);
  g_autoptr(GrlColor) fg     = lrg_color (fg_px);
  g_autoptr(GrlColor) fgdim  = lrg_menu_blend (bg_px, fg_px, 0.45, 255);
  g_autoptr(GrlColor) shadow = grl_color_new (0, 0, 0, 60);
  int d, i;

  for (d = 0; d < st->depth; d++)
    {
      LrgMenuPanel *p = &st->panel[d];

      lrg_frame_surface_fill_rect (surf, p->x + 3, p->y + 3, p->w, p->h,
                                   shadow);
      lrg_frame_surface_fill_rect (surf, p->x, p->y, p->w, p->h, panel);
      lrg_frame_surface_draw_rect_outline (surf, p->x, p->y, p->w, p->h,
                                           1.0f, border);
      for (i = 0; i < p->n; i++)
        {
          LrgMenuItem *it = &p->items[i];
          int ry = p->y + lrg_menu_row_top (st, p, i);
          int rh = lrg_menu_item_h (st, it);

          if (it->label == NULL)                /* separator */
            {
              int sy = ry + rh / 2;
              lrg_frame_surface_draw_line (surf, p->x + st->pad_x, sy,
                                           p->x + p->w - st->pad_x, sy,
                                           1.0f, sep);
              continue;
            }
          if (i == p->hovered)
            lrg_frame_surface_fill_rect (surf, p->x + 2, ry, p->w - 4,
                                         rh, hi);
          lrg_menu_draw_text (f, p->x + st->pad_x, ry, it->label,
                              it->enabled ? fg : fgdim);
          if (it->children != NULL)
            lrg_menu_draw_arrow (surf, p->x + p->w - st->arrow_w + 2, ry,
                                 rh, it->enabled ? fg : fgdim);
        }
    }
}

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

/* Walk the window tree, giving each leaf window's pixel rect to the 3D surface
   (keyed by the stable `struct window' address).  */
static void
lrg_sync_3d_window (Lrg3DSurface *s3, Lisp_Object w)
{
  while (!NILP (w) && WINDOWP (w))
    {
      struct window *win = XWINDOW (w);
      Lisp_Object contents = win->contents;

      if (WINDOWP (contents))
        lrg_sync_3d_window (s3, contents);
      else if (BUFFERP (contents))
        lrg_3d_surface_sync_window (s3, (guintptr) win,
                                    WINDOW_LEFT_PIXEL_EDGE (win),
                                    WINDOW_TOP_PIXEL_EDGE (win),
                                    WINDOW_PIXEL_WIDTH (win),
                                    WINDOW_PIXEL_HEIGHT (win));
      w = win->next;
    }
}

/* Feed F's window tree to its 3D surface so the per-window / free arrangements
   map each Emacs window to a panel.  No-op on a 2D surface or the single-panel
   arrangement (which uses one whole-frame panel).  */
static void
lrg_sync_3d_panels (struct frame *f, LrgFrameSurface *surf)
{
  Lrg3DSurface *s3;
  const char *arr;

  if (surf == NULL || !LRG_IS_3D_SURFACE (surf))
    return;
  s3 = LRG_3D_SURFACE (surf);
  arr = lrg_3d_surface_get_arrangement_id (s3);
  if (arr == NULL
      || (strcmp (arr, "per-window") != 0 && strcmp (arr, "free") != 0))
    return;

  lrg_3d_surface_begin_window_sync (s3);
  lrg_sync_3d_window (s3, f->root_window);
  lrg_3d_surface_end_window_sync (s3);
}

/* Composite each visible child frame of PARENT as an in-window overlay.  A child
   frame has no surface of its own; we point its RIF draws at PARENT's surface
   through a draw offset = the child's (left, top), paint a solid background + a
   1px border (so the popup is opaque/framed), then expose_frame() it -- exactly
   how the parent draws itself, shifted into place and clipped to its rect.
   Called inside the parent's present BEFORE end_content, so in 3D the overlay is
   captured onto the panel and in 2D it lands straight on the framebuffer.  This
   is what makes child-frame UIs (corfu/company popups, posframe, tooltips) show
   under the single-window lrg backend.  */
static void
lrg_composite_child_frames (struct frame *parent, LrgFrameSurface *surf)
{
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *c = XFRAME (frame);
      g_autoptr (GrlColor) cbg = NULL;
      g_autoptr (GrlColor) cborder = NULL;
      int x, y, cw, ch;

      if (!FRAME_LIVE_P (c) || !FRAME_LRG_P (c)
          || FRAME_PARENT_FRAME (c) != parent || !FRAME_VISIBLE_P (c))
        continue;

      x = c->left_pos;
      y = c->top_pos;
      cw = FRAME_PIXEL_WIDTH (c);
      ch = FRAME_PIXEL_HEIGHT (c);
      if (cw <= 0 || ch <= 0)
        continue;

      cbg = lrg_color (FRAME_LRG_BACKGROUND_COLOR (c));
      cborder = lrg_color (FRAME_LRG_FOREGROUND_COLOR (c));

      lrg_frame_surface_fill_rect (surf, x, y, cw, ch, cbg);
      lrg_frame_surface_draw_rect_outline (surf, x, y, cw, ch, 1.0f, cborder);

      /* Draw the child's content at (x,y), clipped to its rect, via the offset. */
      lrg_frame_surface_push_clip (surf, x, y, cw, ch);
      lrg_frame_surface_set_draw_offset (surf, x, y);
      FRAME_LRG_OUTPUT (c)->surface = surf;   /* temporary: for the RIF hooks */
      lrg_drawing = true;
      expose_frame (c, 0, 0, cw, ch);
      lrg_drawing = false;
      FRAME_LRG_OUTPUT (c)->surface = NULL;
      lrg_frame_surface_set_draw_offset (surf, 0, 0);
      lrg_frame_surface_pop_clip (surf);
    }
}

static void
lrg_present_frame (struct frame *f)
{
  LrgFrameSurface *surf;

  if (!FRAME_LRG_P (f))
    return;
  surf = FRAME_LRG_SURFACE (f);

  /* A child frame has no surface of its own: re-present its parent, which
     composites the child as an in-window overlay.  */
  if (surf == NULL)
    {
      struct frame *p = FRAME_PARENT_FRAME (f);
      if (p != NULL && FRAME_LIVE_P (p) && FRAME_LRG_P (p)
          && FRAME_LRG_SURFACE (p) != NULL)
        lrg_present_frame (p);
      return;
    }

  /* Re-entrancy guard only: callers (frame_up_to_date /
     buffer_flipping_unblocked) ensure flips are not blocked.  */
  if (lrg_drawing)
    return;

  /* Off-screen workspace render in progress: swallow the present so the
     redisplay that builds a non-current workspace's matrices stays off screen
     and leaves the live panels untouched (see lrg_present_suppressed).  */
  if (lrg_present_suppressed)
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

    /* Per-window arrangements map each Emacs window to its own panel; feed the
       window tree to the surface before the content pass (no-op in 2D and in
       the single-panel arrangement).  */
    lrg_sync_3d_panels (f, surf);

    /* In 3D the flat frame is rasterised to the default framebuffer between
       begin_content/end_content, then captured onto the panel textures and the
       3D scene is composited in end_frame.  Both hooks are no-ops on the 2D
       surface, so the 2D present path below is unchanged.  */
    lrg_frame_surface_begin_content (surf);

    lrg_drawing = true;
    expose_frame (f, 0, 0, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f));
    lrg_drawing = false;

#ifdef HAVE_CMACS_LIBREGNUM
    /* Composite any cmacs-libregnum 3D buffers (editor/gnuseye/CAD/STL) on
       top of the text, into their windows' rects.  */
    lrg_paint_libregnum_views (f);
#endif

    /* Composite child frames (corfu/posframe/tooltip popups) as overlays.
       Before end_content so 3D captures them onto the panel; 2D no-op there.  */
    lrg_composite_child_frames (f, surf);

    /* Capture the flat frame onto the 3D panels (no-op in 2D).  */
    lrg_frame_surface_end_content (surf);

#ifdef HAVE_CMACS_LIBREGNUM
    /* Refresh the cockpit back-wall texture (gnuseye globe / dashboard).  */
    lrg_feed_cockpit_wall (f, surf);
#endif

    /* The in-engine right-click menu, if one is up, draws on top of all. */
    if (lrg_active_menu != NULL)
      lrg_menu_render (f, surf, lrg_active_menu);

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

/* Return the live output_lrg frame that OWNS the raylib window, or NULL.
   Must skip child frames (corfu/posframe popups): they are output_lrg too but
   have no surface of their own (FRAME_LRG_SURFACE == NULL) -- they are composited
   into the parent's window.  A child frame is often FIRST in Vframe_list (created
   most recently), so returning it here would make lrg_read_socket pick a NULL
   window and bail -- freezing all keyboard input the moment a popup appears.  */
static struct frame *
lrg_any_frame (void)
{
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);
      if (FRAME_LIVE_P (f) && FRAME_LRG_P (f) && FRAME_LRG_SURFACE (f) != NULL)
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

/* Advance an in-progress 3D transition animation (camera / focus / resize ease)
   and recompose the scene from the cached panel textures -- a present WITHOUT a
   re-expose, so it is cheap and needs no Emacs redisplay.  Called ~60 Hz from
   lrg_read_socket (the input timerfd).  No-op on 2D or a settled 3D scene.  */
static void
lrg_animate_tick (void)
{
  struct frame *f = lrg_any_frame ();
  LrgFrameSurface *surf;
  Lrg3DSurface *s3;

  if (f == NULL || !FRAME_LRG_P (f))
    return;
  surf = FRAME_LRG_SURFACE (f);
  if (surf == NULL || !LRG_IS_3D_SURFACE (surf))
    return;
  s3 = LRG_3D_SURFACE (surf);
  if (lrg_drawing || !lrg_3d_surface_is_animating (s3))
    return;

  block_input ();
  lrg_3d_surface_step (s3, 1.0f / 60.0f);
  lrg_frame_surface_begin_frame (surf);
  lrg_frame_surface_end_frame (surf);
  unblock_input ();
}

/* Defined below (in the DEFUN section); used by the spatial mouse handler. */
static Lrg3DSurface *lrg_3d_surface_of_frame (struct frame *f);

/* Recompose the 3D scene NOW from the cached panel textures (begin_frame +
   end_frame, no content re-expose) -- used after an immediate spatial change
   (drag-orbit / panel move) that does not start an animation, so it shows up
   without waiting for the next redisplay.  No-op on 2D or while drawing.  */
static void
lrg_recompose_now (struct frame *f)
{
  LrgFrameSurface *surf;

  if (f == NULL || !FRAME_LRG_P (f))
    return;
  surf = FRAME_LRG_SURFACE (f);
  if (surf == NULL || !LRG_IS_3D_SURFACE (surf) || lrg_drawing)
    return;

  block_input ();
  lrg_frame_surface_begin_frame (surf);
  lrg_frame_surface_end_frame (surf);
  unblock_input ();
}

/* Default mouse spatial-navigation bindings (all rebindable in Elisp): middle-
   drag orbits the scene; Ctrl/Super + middle-drag moves the panel under the
   pointer; Ctrl + left-click peeks focus, Ctrl + double-left flies a panel
   front-and-centre.  The high-rate drag is handled here in C (no Lisp
   round-trip), routed through the device-agnostic lrg_3d_surface_* intents. */
#define LRG_DRAG_THRESHOLD     3       /* px before a middle press is a drag */
#define LRG_DOUBLE_CLICK_SECS  0.45    /* Ctrl+left double-click window */
#define LRG_ORBIT_DEG_PER_PX   0.4f    /* middle-drag orbit sensitivity */
#define LRG_LOOK_DEG_PER_PX    0.25f   /* Ctrl+left-drag first-person look */

static struct
{
  bool   middle_down;
  bool   dragging;        /* moved past the threshold during this press */
  bool   moving_panel;    /* this drag moves a panel (Ctrl/Super), else orbit */
  int    press_x, press_y;
  int    last_x, last_y;
  double last_left_t;     /* time of the last Ctrl+left press (double-click) */
  int    last_left_x, last_left_y;

  /* Ctrl+left: drag = first-person camera look; click = focus a panel. */
  bool   cl_down;
  bool   cl_dragging;
  int    cl_press_x, cl_press_y;
  int    cl_last_x, cl_last_y;
} lrg_sp;

/* TRUE when frame pixel (FX,FY) lies in a window whose buffer hosts a libregnum
   view (gnuseye / libregnum-editor / CAD / ...).  The 3D spatial gestures defer
   to such a window so those apps keep their own camera controls -- the lrg scene
   never steals middle-drag / Ctrl+wheel from them.  */
static bool
lrg_over_libregnum_view (struct frame *f, int fx, int fy)
{
#ifdef HAVE_CMACS_LIBREGNUM
  Lisp_Object w = window_from_coordinates (f, fx, fy, NULL, false, false, false);
  if (WINDOWP (w))
    return cmacs_libregnum_view_for_buffer (XWINDOW (w)->contents) != NULL;
#else
  (void) f; (void) fx; (void) fy;
#endif
  return false;
}

/* --- Gamepad / 6DOF spatial control (the device-agnostic binding backend) ---
   A libregnum LrgInputMap maps named actions to gamepad axes; each tick we read
   the SIGNED axis values and drive the SAME orbit / pan / dolly intents the mouse
   uses, so a gamepad (or a 6DOF SpaceMouse exposed as a joystick) "just works".
   The map is data: cmacs-lrg-3d-load-gamepad-bindings loads a YAML remap.  No-op
   without a gamepad, so it is safe and costs nothing when idle.  */
#define LRG_PAD_DEADZONE   0.18f
#define LRG_PAD_ORBIT_DPS  2.5f    /* degrees per tick at full stick deflection */
#define LRG_PAD_PAN        0.06f
#define LRG_PAD_DOLLY      0.03f
#define LRG_PAD_ABS(v)     ((v) < 0.0f ? -(v) : (v))
#define LRG_PAD_DZ(v)      (LRG_PAD_ABS (v) < LRG_PAD_DEADZONE ? 0.0f : (v))

static LrgInputMap *lrg_gamepad_map;   /* lazily built default map, owned */

/* Build (once) the default spatial input map: right stick = orbit, left stick =
   pan, triggers = dolly.  Every binding is a gamepad-axis binding read as a
   signed analog value via lrg_input_map_get_axis.  */
static LrgInputMap *
lrg_gamepad_ensure_map (void)
{
  static const struct { const char *name; int axis; } defs[] = {
    { "orbit-yaw",   GRL_GAMEPAD_AXIS_RIGHT_X },
    { "orbit-pitch", GRL_GAMEPAD_AXIS_RIGHT_Y },
    { "pan-x",       GRL_GAMEPAD_AXIS_LEFT_X },
    { "pan-y",       GRL_GAMEPAD_AXIS_LEFT_Y },
    { "dolly-in",    GRL_GAMEPAD_AXIS_RIGHT_TRIGGER },
    { "dolly-out",   GRL_GAMEPAD_AXIS_LEFT_TRIGGER },
  };
  gsize i;

  if (lrg_gamepad_map != NULL)
    return lrg_gamepad_map;

  lrg_gamepad_map = lrg_input_map_new ();
  for (i = 0; i < G_N_ELEMENTS (defs); i++)
    {
      LrgInputAction *a = lrg_input_action_new (defs[i].name);
      g_autoptr (LrgInputBinding) b =
        lrg_input_binding_new_gamepad_axis (0, (GrlGamepadAxis) defs[i].axis,
                                            0.0f, TRUE);
      lrg_input_action_add_binding (a, b);   /* copies b */
      lrg_input_map_add_action (lrg_gamepad_map, a);   /* takes ownership */
    }
  return lrg_gamepad_map;
}

/* Drive the camera from a connected gamepad (called ~60 Hz from read_socket).
   No-op on a 2D frame, while a mouse drag is active, or with no gamepad.  */
static void
lrg_gamepad_tick (struct frame *f)
{
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  LrgInputManager *mgr;
  LrgInputMap *map;
  LrgSpatialCamera *cam;
  gfloat yaw, pitch, panx, pany, din, dout, dz;
  bool moved = false;

  if (s3 == NULL || lrg_drawing || lrg_sp.middle_down)
    return;
  mgr = lrg_input_manager_get_default ();
  if (mgr == NULL || !lrg_input_manager_is_gamepad_available (mgr, 0))
    return;                                 /* no hardware -> no-op */
  cam = lrg_3d_surface_get_camera (s3);
  if (cam == NULL)
    return;

  lrg_input_manager_poll (mgr);             /* latches live state, no glfw poll */
  map = lrg_gamepad_ensure_map ();

  yaw   = LRG_PAD_DZ (lrg_input_map_get_axis (map, "orbit-yaw"));
  pitch = LRG_PAD_DZ (lrg_input_map_get_axis (map, "orbit-pitch"));
  panx  = LRG_PAD_DZ (lrg_input_map_get_axis (map, "pan-x"));
  pany  = LRG_PAD_DZ (lrg_input_map_get_axis (map, "pan-y"));
  /* Triggers rest negative; only count a real squeeze. */
  din   = lrg_input_map_get_axis (map, "dolly-in");
  dout  = lrg_input_map_get_axis (map, "dolly-out");
  dz    = (din > LRG_PAD_DEADZONE ? din : 0.0f)
          - (dout > LRG_PAD_DEADZONE ? dout : 0.0f);

  if (yaw != 0.0f || pitch != 0.0f)
    {
      lrg_3d_surface_orbit_room (s3, -yaw * LRG_PAD_ORBIT_DPS,
                                 -pitch * LRG_PAD_ORBIT_DPS);
      moved = true;
    }
  if (panx != 0.0f || pany != 0.0f)
    {
      lrg_spatial_camera_pan_drag (cam, panx * LRG_PAD_PAN,
                                   -pany * LRG_PAD_PAN);
      moved = true;
    }
  if (dz != 0.0f)
    {
      lrg_spatial_camera_dolly_drag (cam, 1.0f - dz * LRG_PAD_DOLLY);
      moved = true;
    }
  if (moved)
    lrg_recompose_now (f);
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

/* Pull the next *text* character from the Unicode char queue, skipping control
   characters (< 0x20 and DEL 0x7f).  Tab, Return, Escape and Backspace are
   FUNCTION keys handled via the key-press queue (as X keysyms); GLFW may ALSO
   deliver them as their control char (e.g. Tab -> 0x09) in the char queue.  If
   such a char were consumed as text it would double-emit the key AND shift the
   per-printable-key char pairing by one -- so the key typed right after a Tab
   would eat the Tab's stray char and lose its own (e.g. `SPC TAB 1' arriving as
   `SPC 1', intermittently, depending on whether GLFW emitted the Tab char this
   poll).  Real Ctrl-char input (C-i, C-m, ...) comes via the key+modifier path,
   not the text queue, so dropping these here loses nothing.  */
static int
lrg_next_text_char (void)
{
  int cp;

  while ((cp = grl_input_get_char_pressed ()) != 0)
    if (cp >= 0x20 && cp != 0x7f)
      return cp;
  return 0;
}

/* Optional keystroke tracing: set CMACS_LRG_KEYLOG=1 in the environment to have
   lrg_read_socket print every key/char it pulls from the GLFW queues and emits
   into Emacs (to stderr, prefixed "[lrgkey]").  Off by default, ~zero cost when
   off.  Use it to localise a dropped/mis-ordered key: if the trace shows the key
   leaving read_socket, the loss is above this layer (a binding / translation);
   if it never appears, the loss is in the windowing/input layer.  */
static int lrg_keylog = -1;            /* -1 = unread, 0 = off, 1 = on */

static bool
lrg_keylog_on (void)
{
  if (lrg_keylog < 0)
    lrg_keylog = (getenv ("CMACS_LRG_KEYLOG") != NULL) ? 1 : 0;
  return lrg_keylog == 1;
}

/* The last "special" key (a mapped non-character key, or a printable key with
   Ctrl/Meta held) emitted from the press queue -- held down, it auto-repeats at
   the OS rate (see the repeat scan in lrg_read_socket).  Plain printable keys
   repeat via the char queue, so they are NOT tracked here.  */
static GrlKey lrg_repeat_key = GRL_KEY_NULL;

/* Emit the keystroke for a "special" key K (the keysym path, or a Ctrl/Meta +
   printable synthesised char).  Returns the number of events stored (0 if K is a
   plain printable key with no modifier, which is handled via the char queue).
   Shared by the initial press and the auto-repeat.  */
static int
lrg_emit_special_key (struct frame *f, struct input_event *hold_quit,
                      GrlKey k, int mods)
{
  int keysym = lrg_keysym_for (k);

  if (keysym != 0)
    {
      struct input_event ie;
      EVENT_INIT (ie);
      ie.kind = NON_ASCII_KEYSTROKE_EVENT;
      ie.code = keysym;
      ie.modifiers = mods;
      ie.timestamp = 0;
      return lrg_store (f, hold_quit, &ie);
    }
  if (k >= GRL_KEY_SPACE && k <= GRL_KEY_GRAVE
      && (mods & (ctrl_modifier | meta_modifier)) != 0)
    {
      int code = (int) k;
      if (code >= GRL_KEY_A && code <= GRL_KEY_Z)
        code += 32;            /* 'A'..'Z' -> 'a'..'z' so C-A == C-a */
      return lrg_store_char (f, hold_quit, code, mods);
    }
  return 0;
}

/* Map a raw device pixel to a frame pixel via the surface pick: a 3D ray-cast
   onto the panel under the pointer, or identity on a 2D surface.  Returns FALSE
   when a 3D ray misses every panel (pointer in empty space), so the caller can
   skip the highlight / click there.  */
static gboolean
lrg_pick_xy (struct frame *f, int mx, int my, int *fx, int *fy)
{
  LrgFrameSurface *s = FRAME_LRG_P (f) ? FRAME_LRG_SURFACE (f) : NULL;
  gfloat ox = 0.0f, oy = 0.0f;

  if (s == NULL)
    {
      *fx = mx;
      *fy = my;
      return TRUE;
    }
  if (!lrg_frame_surface_pick (s, (gfloat) mx, (gfloat) my, &ox, &oy))
    return FALSE;
  *fx = (int) ox;
  *fy = (int) oy;
  return TRUE;
}

/* Pending keys dequeued from the GLFW key-press queue but not yet emitted because
   their text character had not arrived in the SAME poll.  On XWayland / Wayland,
   GLFW can deliver a key event and its character event in SEPARATE poll cycles
   (the char lags the key by one or more 16 ms polls), so a printable key and its
   Unicode char are not guaranteed to be visible together.  If we emitted a
   printable key only once its char was ready but emitted keysym keys (Tab, RET,
   arrows) immediately, a Tab pressed right after Space would jump AHEAD of the
   not-yet-charred Space -- reordering `SPC TAB n' into `<tab> SPC n', which Emacs
   sees as `SPC n' (a real bug observed under XWayland; invisible on a native X
   server, where key+char arrive in one poll).  So pending keys are held here, IN
   ORDER, and retried on later polls: a keysym key never overtakes an earlier
   printable key that is still waiting for its character.  */
#define LRG_KEYQ_MAX 256
#define LRG_KEYQ_MAX_WAIT 8     /* polls to wait for a char before synthesising */
static GrlKey lrg_keyq[LRG_KEYQ_MAX];
static int lrg_keyq_mods[LRG_KEYQ_MAX];   /* modifiers snapshot at dequeue time */
static int lrg_keyq_len;
static int lrg_keyq_wait;        /* polls the head printable key has waited */

/* Drain the GLFW key/char queues into Emacs, preserving press order even when a
   printable key's character lags into a later poll (see lrg_keyq above).  MODS is
   the current modifier state.  Returns the number of input events stored.  */
static int
lrg_drain_keys (struct frame *f, struct input_event *hold_quit, int mods)
{
  int count = 0;
  int i;
  GrlKey k;
  int cp;

  /* Append newly pressed keys (with a modifier snapshot) to the pending queue. */
  while ((k = grl_input_get_key_pressed ()) != GRL_KEY_NULL)
    if (lrg_keyq_len < LRG_KEYQ_MAX)
      {
        lrg_keyq[lrg_keyq_len] = k;
        lrg_keyq_mods[lrg_keyq_len] = mods;
        lrg_keyq_len++;
      }

  /* Emit pending keys from the front, stopping at the first plain printable key
     whose character has not arrived yet (it will pair on a later poll).  */
  for (i = 0; i < lrg_keyq_len; )
    {
      int km = lrg_keyq_mods[i];
      bool kcm = (km & (ctrl_modifier | meta_modifier)) != 0;
      int keysym;
      bool printable;

      k = lrg_keyq[i];
      keysym = lrg_keysym_for (k);
      printable = k >= GRL_KEY_SPACE && k <= GRL_KEY_GRAVE;

      if (keysym != 0 || (printable && kcm))
        {
          /* Keysym, or Ctrl/Meta + printable: needs no char from the queue. */
          if (lrg_keylog_on ())
            fprintf (stderr,
                     "[lrgkey] key=%d keysym=0x%x mods=0x%x -> special\n",
                     (int) k, (unsigned) keysym, (unsigned) km);
          count += lrg_emit_special_key (f, hold_quit, k, km);
          lrg_repeat_key = k;
          lrg_keyq_wait = 0;
          i++;
        }
      else if (printable)
        {
          cp = lrg_next_text_char ();
          if (cp == 0)
            {
              /* Char not here yet: wait for a later poll.  But never stall
                 forever on a key that yields no char -- after a bound, fall back
                 to the US-ASCII keycode (lower-cased for letters).  */
              if (lrg_keyq_wait < LRG_KEYQ_MAX_WAIT)
                {
                  lrg_keyq_wait++;
                  break;
                }
              cp = (int) k;
              if (cp >= GRL_KEY_A && cp <= GRL_KEY_Z)
                cp += 32;
            }
          if (lrg_keylog_on ())
            fprintf (stderr, "[lrgkey] key=%d -> char %d (%c)\n",
                     (int) k, cp, (cp >= 32 && cp < 127) ? cp : '?');
          count += lrg_store_char (f, hold_quit, cp,
                                   km & ~(ctrl_modifier | meta_modifier));
          lrg_keyq_wait = 0;
          i++;
        }
      else
        {
          /* A modifier or unmapped/keypad key: drop it. */
          if (lrg_keylog_on ())
            fprintf (stderr, "[lrgkey] key=%d -> skipped (modifier/unmapped)\n",
                     (int) k);
          i++;
        }
    }

  /* Remove the emitted prefix [0, i) from the pending queue. */
  if (i > 0)
    {
      memmove (lrg_keyq, lrg_keyq + i,
               (lrg_keyq_len - i) * sizeof lrg_keyq[0]);
      memmove (lrg_keyq_mods, lrg_keyq_mods + i,
               (lrg_keyq_len - i) * sizeof lrg_keyq_mods[0]);
      lrg_keyq_len -= i;
    }

  /* Once no printable key is waiting, drain remaining characters in order -- IME
     commits, pasted text, and held-key auto-repeat (GLFW's char callback fires on
     repeat).  When a key IS waiting the text queue is empty (that is why we
     stopped), so skipping it then loses nothing.  Suppressed while Ctrl/Meta is
     held so stray chars are not inserted as literal text.  */
  if (lrg_keyq_len == 0 && !lrg_ctrl_or_meta_down ())
    while ((cp = lrg_next_text_char ()) != 0)
      {
        if (lrg_keylog_on ())
          fprintf (stderr, "[lrgkey] trailing char %d (%c)\n",
                   cp, (cp >= 32 && cp < 127) ? cp : '?');
        count += lrg_store_char (f, hold_quit, cp,
                                 mods & ~(ctrl_modifier | meta_modifier));
      }

  return count;
}

#ifdef HAVE_CMACS_GSURF_LRG
/* When a gsurf-lrg web page holds focus, route raylib keys to it instead of
   to Emacs.  Escape always returns control to Emacs (releases page focus).
   Reuses the same key/char primitives as lrg_drain_keys so the queues are
   fully consumed this poll (lrg_drain_keys is skipped while focused).  */
static void
lrg_route_keys_to_gsurf (struct frame *f, int mods)
{
  GrlKey k;
  int cp;
  bool kcm = (mods & (ctrl_modifier | meta_modifier)) != 0;

  while ((k = grl_input_get_key_pressed ()) != GRL_KEY_NULL)
    {
      int keysym;
      bool printable;

      if (k == GRL_KEY_ESCAPE)
        {
          /* Let the modal module clean up first (clear a link-hint overlay,
             leave INSERT/FOLLOW mode), then unconditionally hand keys back to
             Emacs -- Escape is always "return to the editor".  */
          cmacs_gsurf_lrg_handle_key (f, 0xFF1B /* XK_Escape */, 0, mods);
          cmacs_gsurf_release_focus ();
          continue;
        }
      keysym = lrg_keysym_for (k);
      printable = (k >= GRL_KEY_SPACE && k <= GRL_KEY_GRAVE);
      if (keysym != 0)
        cmacs_gsurf_lrg_handle_key (f, keysym, 0, mods);
      else if (printable && kcm)
        {
          /* Ctrl/Meta + printable: send the (lower-cased) letter keysym so
             the page sees e.g. C-a / C-c. */
          int sym = (k >= GRL_KEY_A && k <= GRL_KEY_Z) ? (int) k + 32 : (int) k;
          cmacs_gsurf_lrg_handle_key (f, sym, 0, mods);
        }
      /* plain printable keys are delivered as text below */
    }

  if (!kcm)
    while ((cp = lrg_next_text_char ()) != 0)
      cmacs_gsurf_lrg_handle_key (f, 0, cp, mods);
}
#endif

static int
lrg_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  struct lrg_display_info *dpyinfo = terminal->display_info.lrg;
  struct frame *f;
  GrlWindow *win;
  int count = 0;
  int mods;

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
     misses or repeats a fast tap the way a per-frame state scan does, which is
     what made ESC/hjkl flaky under Evil).  lrg_drain_keys handles the mapping:
       - a mapped non-character key (ESC, arrows, Tab, RET, ...) -> a
         NON_ASCII_KEYSTROKE_EVENT carrying its X keysym + modifiers;
       - a printable key with Ctrl/Meta held -> a char event with modifiers
         (GLFW emits no char callback for those, so synthesise from the US-ASCII
         keycode, lower-casing letters so C-A == C-a);
       - a printable key with no Ctrl/Meta consumes the next Unicode char from
         the char queue (which already encodes layout + shift).
     Keys whose char has not arrived yet are held in order across polls so a
     later keysym key never overtakes them (see lrg_drain_keys / lrg_keyq).  */
#ifdef HAVE_CMACS_GSURF_LRG
  /* A focused gsurf-lrg page eats keys (except Escape, which releases it). */
  if (cmacs_gsurf_lrg_page_focused_p (f))
    lrg_route_keys_to_gsurf (f, mods);
  else
#endif
    count += lrg_drain_keys (f, hold_quit, mods);

  /* Auto-repeat the held special key (keysym / Ctrl|Meta+printable) at the OS
     repeat rate -- those never reach the char queue, so without this they only
     fire once per physical press (e.g. holding C-e would not scroll).  */
  if (lrg_repeat_key != GRL_KEY_NULL)
    {
      if (!grl_input_is_key_down (lrg_repeat_key))
        lrg_repeat_key = GRL_KEY_NULL;
      else if (grl_input_is_key_pressed_repeat (lrg_repeat_key))
        count += lrg_emit_special_key (f, hold_quit, lrg_repeat_key, mods);
    }

  /* 3D spatial navigation (precedes the generic mouse handling on a 3D lrg
     frame): middle-drag orbits, Ctrl/Super+middle-drag moves the panel under
     the pointer, Ctrl+left peeks/focuses a panel.  Whatever it uses is gated
     out of the generic motion/click handlers via the sp_skip_* flags.  */
  bool sp_skip_motion = false;
  bool sp_skip_middle = false;
  bool sp_skip_left = false;
  {
    Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
    if (s3 != NULL && grl_window_is_focused (win))
      {
        int mx = grl_input_get_mouse_x ();
        int my = grl_input_get_mouse_y ();
        bool ctrl = (mods & ctrl_modifier) != 0;
        bool spatial_mod = (mods & (ctrl_modifier | super_modifier)) != 0;
        bool mid_pressed =
          grl_input_is_mouse_button_pressed (GRL_MOUSE_BUTTON_MIDDLE);
        bool mid_released =
          grl_input_is_mouse_button_released (GRL_MOUSE_BUTTON_MIDDLE);
        bool left_pressed =
          grl_input_is_mouse_button_pressed (GRL_MOUSE_BUTTON_LEFT);
        bool left_released =
          grl_input_is_mouse_button_released (GRL_MOUSE_BUTTON_LEFT);
        int fx, fy;
        /* Defer to a libregnum-view window under the pointer (gnuseye / editor):
           starting a gesture there must not steal its camera controls.  */
        bool over_view =
          lrg_pick_xy (f, mx, my, &fx, &fy) && lrg_over_libregnum_view (f, fx, fy);

        /* Ctrl+left: a DRAG turns the camera in place (first-person "look" about
           the eye -- the camera stays put and the view swings around it); a CLICK
           (no drag) focuses the panel under it -- peek on a single click, fly
           front-and-centre on a double click.  Always consumed, so Ctrl+left
           never places point.  */
        if (left_pressed && ctrl && !over_view)
          {
            lrg_sp.cl_down = true;
            lrg_sp.cl_dragging = false;
            lrg_sp.cl_press_x = lrg_sp.cl_last_x = mx;
            lrg_sp.cl_press_y = lrg_sp.cl_last_y = my;
            sp_skip_left = true;
          }
        if (lrg_sp.cl_down && !left_released
            && (mx != lrg_sp.cl_last_x || my != lrg_sp.cl_last_y))
          {
            if (!lrg_sp.cl_dragging
                && (abs (mx - lrg_sp.cl_press_x) > LRG_DRAG_THRESHOLD
                    || abs (my - lrg_sp.cl_press_y) > LRG_DRAG_THRESHOLD))
              lrg_sp.cl_dragging = true;
            if (lrg_sp.cl_dragging)
              {
                LrgSpatialCamera *cam = lrg_3d_surface_get_camera (s3);
                if (cam != NULL)
                  /* Drag right -> look right, drag up -> look up (FPS feel). */
                  lrg_spatial_camera_look_drag
                    (cam,
                     (gfloat) (mx - lrg_sp.cl_last_x) * LRG_LOOK_DEG_PER_PX,
                     -(gfloat) (my - lrg_sp.cl_last_y) * LRG_LOOK_DEG_PER_PX);
                lrg_recompose_now (f);
                sp_skip_motion = true;
              }
            lrg_sp.cl_last_x = mx;
            lrg_sp.cl_last_y = my;
            sp_skip_left = true;
          }
        if (left_released && lrg_sp.cl_down)
          {
            if (!lrg_sp.cl_dragging)
              {
                /* A click (not a drag): focus the panel under the pointer. */
                double now = grl_window_get_time (win);
                guint64 key = 0;
                bool hit = lrg_3d_surface_pick_panel (s3, (gfloat) mx,
                                                      (gfloat) my, NULL, NULL,
                                                      &key);
                bool dbl = (now - lrg_sp.last_left_t) < LRG_DOUBLE_CLICK_SECS
                           && abs (mx - lrg_sp.last_left_x) < 6
                           && abs (my - lrg_sp.last_left_y) < 6;
                if (hit)
                  {
                    if (dbl && LRG_WS_IS_KEY (key))
                      /* Double-click on a workspace panel: request a switch to it
                         (consumed in the command loop -- never call Lisp here). */
                      lrg_pending_ws_select = LRG_WS_KEY_INDEX (key);
                    else if (dbl)
                      lrg_3d_surface_focus_panel (s3, key);
                    else
                      lrg_3d_surface_set_focus_window (s3, key);
                    lrg_recompose_now (f);
                  }
                lrg_sp.last_left_t = dbl ? 0.0 : now;
                lrg_sp.last_left_x = mx;
                lrg_sp.last_left_y = my;
              }
            lrg_sp.cl_down = false;
            lrg_sp.cl_dragging = false;
            sp_skip_left = true;
          }

        /* Middle press arms a drag; motion past the threshold starts orbit (or a
           panel move with Ctrl/Super); release ends it, or emits a bare mouse-2
           click when nothing was dragged (so middle-click yank still works).  */
        if (mid_pressed && !over_view)
          {
            lrg_sp.middle_down = true;
            lrg_sp.dragging = false;
            lrg_sp.moving_panel = spatial_mod;
            lrg_sp.press_x = lrg_sp.last_x = mx;
            lrg_sp.press_y = lrg_sp.last_y = my;
            sp_skip_middle = true;
          }
        if (lrg_sp.middle_down && !mid_released
            && (mx != lrg_sp.last_x || my != lrg_sp.last_y))
          {
            if (!lrg_sp.dragging
                && (abs (mx - lrg_sp.press_x) > LRG_DRAG_THRESHOLD
                    || abs (my - lrg_sp.press_y) > LRG_DRAG_THRESHOLD))
              {
                lrg_sp.dragging = true;
                if (lrg_sp.moving_panel)
                  {
                    guint64 key = 0;
                    if (lrg_3d_surface_pick_panel (s3, (gfloat) lrg_sp.press_x,
                                                   (gfloat) lrg_sp.press_y,
                                                   NULL, NULL, &key))
                      lrg_3d_surface_grab_panel (s3, key,
                                                 (gfloat) lrg_sp.press_x,
                                                 (gfloat) lrg_sp.press_y);
                    else
                      lrg_sp.moving_panel = false;  /* missed -> orbit instead */
                  }
              }
            if (lrg_sp.dragging)
              {
                if (lrg_sp.moving_panel)
                  lrg_3d_surface_drag_panel (s3, (gfloat) mx, (gfloat) my);
                else
                  /* Orbit the whole room (scene centroid), not the focused
                     panel, so middle-drag is a "look around the workspace". */
                  lrg_3d_surface_orbit_room
                    (s3,
                     -(gfloat) (mx - lrg_sp.last_x) * LRG_ORBIT_DEG_PER_PX,
                     (gfloat) (my - lrg_sp.last_y) * LRG_ORBIT_DEG_PER_PX);
                lrg_recompose_now (f);
                sp_skip_motion = true;
              }
            lrg_sp.last_x = mx;
            lrg_sp.last_y = my;
            sp_skip_middle = true;
          }
        if (mid_released && lrg_sp.middle_down)
          {
            if (!lrg_sp.dragging)
              {
                int pfx, pfy;
                if (lrg_pick_xy (f, mx, my, &pfx, &pfy))
                  {
                    struct input_event ie;
                    EVENT_INIT (ie);
                    ie.kind = MOUSE_CLICK_EVENT;
                    ie.code = 1;   /* Emacs middle button (mouse-2) */
                    XSETINT (ie.x, pfx);
                    XSETINT (ie.y, pfy);
                    ie.timestamp = 0;
                    ie.modifiers = mods | down_modifier;
                    count += lrg_store (f, hold_quit, &ie);
                    ie.modifiers = mods | up_modifier;
                    count += lrg_store (f, hold_quit, &ie);
                  }
              }
            else if (lrg_sp.moving_panel)
              lrg_3d_surface_release_panel (s3);
            lrg_sp.middle_down = false;
            lrg_sp.dragging = false;
            lrg_sp.moving_panel = false;
            sp_skip_middle = true;
          }
      }
  }

  /* Mouse motion.  First offer it to a libregnum view (camera orbit/pan
     while a drag is active); only when not consumed do we update the
     mouse-face highlight (hover on buttons, links, ...).  Mirrors pgtk's
     motion_notify_event short-circuit.  Only when the pointer moved.  */
  {
    static int last_mx = -1, last_my = -1;
    int mx = grl_input_get_mouse_x ();
    int my = grl_input_get_mouse_y ();
    if (!sp_skip_motion && (mx != last_mx || my != last_my)
        && grl_window_is_focused (win))
      {
        int pfx, pfy;
        /* Ray-cast to the frame pixel under the pointer (identity in 2D); a 3D
           ray that misses every panel means empty space (nothing under it).
           Libregnum views and the mouse-face highlight both want frame pixels,
           so pick once and feed the picked coords -- in 3D the view lives on a
           panel, not at the raw device pixel.  */
        last_mx = mx;
        last_my = my;
        if (lrg_pick_xy (f, mx, my, &pfx, &pfy))
          {
#ifdef HAVE_CMACS_LIBREGNUM
            if (!cmacs_libregnum_handle_motion (f, pfx, pfy))
#endif
#ifdef HAVE_CMACS_GSURF_LRG
            if (!cmacs_gsurf_lrg_handle_motion (f, pfx, pfy))
#endif
              {
                block_input ();
                note_mouse_highlight (f, pfx, pfy);
                unblock_input ();
              }
          }
      }
  }

  /* Mouse buttons: press/release -> MOUSE_CLICK_EVENT (Emacs forms the
     click/drag).  raylib button order L,R,M -> Emacs 0,1,2.  */
  {
    static const int rl_to_emacs_button[3] = { 0, 2, 1 };
#if defined(HAVE_CMACS_LIBREGNUM) || defined(HAVE_CMACS_GSURF_LRG)
    /* raylib L,R,M -> X11/GDK 1,3,2, which cmacs_libregnum_handle_button and
       cmacs_gsurf_lrg_handle_button expect (GSURF_BUTTON_* use the same 1/3/2). */
    static const int rl_to_x11_button[3] = { 1, 3, 2 };
#endif
    int b;
    int mx = grl_input_get_mouse_x ();
    int my = grl_input_get_mouse_y ();
    int pfx, pfy;
    /* Ray-cast once to the frame pixel under the pointer (identity in 2D); a 3D
       miss = empty space, so no libregnum view and no text click there.  */
    bool on_panel = lrg_pick_xy (f, mx, my, &pfx, &pfy);
    for (b = 0; b < 3; b++)
      {
        bool pressed = grl_input_is_mouse_button_pressed ((GrlMouseButton) b);
        bool released = grl_input_is_mouse_button_released ((GrlMouseButton) b);
        if (!pressed && !released)
          continue;
        /* The 3D spatial handler already consumed middle (orbit / panel move)
           and Ctrl+left (focus) on a 3D frame -- don't also treat them as text
           clicks.  raylib button order is L=0, R=1, M=2.  */
        if ((b == 2 && sp_skip_middle) || (b == 0 && sp_skip_left))
          continue;
        if (!on_panel)
          continue;
#ifdef HAVE_CMACS_LIBREGNUM
        /* Offer the transition to a libregnum view first, at the PICKED frame
           pixel (so it works when the view is on a 3D panel).  When it consumes
           the event, suppress the matching Emacs click.  Press/release distinct. */
        {
          int x11b = rl_to_x11_button[b];
          if (pressed && cmacs_libregnum_handle_button (f, x11b, 1, pfx, pfy))
            pressed = false;
          if (released && cmacs_libregnum_handle_button (f, x11b, 0, pfx, pfy))
            released = false;
          if (!pressed && !released)
            continue;
        }
#endif
#ifdef HAVE_CMACS_GSURF_LRG
        /* Then offer it to a gsurf-lrg web page (a click also focuses it). */
        {
          int gb = rl_to_x11_button[b];
          if (pressed && cmacs_gsurf_lrg_handle_button (f, gb, 1, pfx, pfy))
            pressed = false;
          if (released && cmacs_gsurf_lrg_handle_button (f, gb, 0, pfx, pfy))
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
          XSETINT (ie.x, pfx);
          XSETINT (ie.y, pfy);
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
        int pfx, pfy;
        bool on_panel = lrg_pick_xy (f, mx, my, &pfx, &pfy);
        bool over_view = on_panel && lrg_over_libregnum_view (f, pfx, pfy);
        Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
        bool consumed = false;

        /* Ctrl+wheel dollies the 3D scene camera (unless over a libregnum view,
           which keeps its own wheel-zoom).  Eased via the recompose tick. */
        if (s3 != NULL && (mods & ctrl_modifier) != 0 && !over_view)
          {
            LrgSpatialCamera *cam = lrg_3d_surface_get_camera (s3);
            if (cam != NULL)
              {
                lrg_spatial_camera_zoom (cam, wheel > 0.0f ? 0.9f : 1.1111f);
                consumed = true;
              }
          }
#ifdef HAVE_CMACS_LIBREGNUM
        /* pgtk passes GDK smooth-scroll dy (wheel-up is negative); raylib's
           wheel-up is positive, so negate to match the zoom direction.  Picked
           coords so a view on a 3D panel still zooms. */
        if (!consumed && on_panel)
          consumed = cmacs_libregnum_handle_scroll (f, 0.0, -(double) wheel,
                                                    pfx, pfy);
#endif
#ifdef HAVE_CMACS_GSURF_LRG
        if (!consumed && on_panel)
          consumed = cmacs_gsurf_lrg_handle_scroll (f, 0.0, -(double) wheel,
                                                    pfx, pfy);
#endif
        if (!consumed)
          {
            struct input_event ie;
            EVENT_INIT (ie);
            ie.kind = WHEEL_EVENT;
            ie.modifiers = mods | (wheel > 0 ? up_modifier : down_modifier);
            XSETINT (ie.x, on_panel ? pfx : mx);
            XSETINT (ie.y, on_panel ? pfy : my);
            XSETFRAME (ie.frame_or_window, f);
            ie.arg = Qnil;
            ie.timestamp = 0;
            count += lrg_store (f, hold_quit, &ie);
          }
      }
  }

  /* Drive the camera from a connected gamepad / 6DOF device (no-op otherwise). */
  lrg_gamepad_tick (f);

  /* Advance any in-progress 3D transition animation (camera / focus / resize)
     and recompose, so eases play out smoothly between redisplays.  */
  lrg_animate_tick ();

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
      int pfx, pfy;
      /* Report the frame pixel under the pointer (ray-cast in 3D, identity in
         2D); fall back to raw coords if a 3D ray misses every panel.  */
      if (!lrg_pick_xy (f, grl_input_get_mouse_x (), grl_input_get_mouse_y (),
                        &pfx, &pfy))
        {
          pfx = grl_input_get_mouse_x ();
          pfy = grl_input_get_mouse_y ();
        }
      *fp = f;
      XSETINT (*x, pfx);
      XSETINT (*y, pfy);
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
  else if (FRAME_PARENT_FRAME (f) != NULL)
    {
      /* Child frame: there is no OS window whose resize callback would confirm
         the new size, so adjust_frame_size just called this (no-op) hook and
         returned WITHOUT applying it (frame.c, the can_set_window_size branch).
         Apply it directly: clear can_set_window_size so the nested
         change_frame_size takes adjust_frame_size's apply path instead of
         re-deferring to this hook (which would also leave it unapplied).  */
      bool saved = f->can_set_window_size;
      f->can_set_window_size = false;
      change_frame_size (f, width, height, false, false, true);
      f->can_set_window_size = saved;
    }
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

/* Re-present a child frame's parent so its in-window overlay re-composites
   (a child has no surface of its own).  No-op for a top-level frame.  */
static void
lrg_present_parent (struct frame *f)
{
  struct frame *p = FRAME_PARENT_FRAME (f);

  if (p != NULL && FRAME_LIVE_P (p) && FRAME_LRG_P (p)
      && FRAME_LRG_SURFACE (p) != NULL)
    lrg_present_frame (p);
}

static void
lrg_make_frame_visible_invisible (struct frame *f, bool visible)
{
  SET_FRAME_VISIBLE (f, visible);
  /* Showing/hiding a child frame changes what the parent composites. */
  if (FRAME_PARENT_FRAME (f) != NULL)
    lrg_present_parent (f);
}

/* set_frame_offset_hook: position a frame.  lrg has no window manager, so a
   top-level frame's screen position is meaningless; a *child* frame stores its
   parent-relative pixel offset (where its overlay is composited) and triggers a
   re-composite.  */
static void
lrg_set_frame_offset (struct frame *f, int xoff, int yoff, int change_gravity)
{
  (void) change_gravity;
  f->left_pos = xoff;
  f->top_pos = yoff;
  if (FRAME_PARENT_FRAME (f) != NULL)
    {
      SET_FRAME_GARBAGED (f);
      lrg_present_parent (f);
    }
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
  terminal->set_frame_offset_hook = lrg_set_frame_offset;
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

DEFUN ("lrg-popup-menu", Flrg_popup_menu, Slrg_popup_menu, 1, 3, 0,
       doc: /* Show an in-engine popup menu of ITEMS; return the chosen index.
ITEMS is a nested list; each element is nil (a separator row), a cons
(LABEL . INDEX) where INDEX is a fixnum (a selectable leaf returning INDEX),
\(LABEL) / (LABEL . nil) (a disabled leaf), or (LABEL ITEM...) where the cdr is
a list (a submenu whose children are ITEM...).  Optional X and Y place the
menu's top-left at that frame pixel; without them it opens at the current mouse
position.  Runs a modal loop driven by the libregnum window with cascading
fly-out submenus (mouse hover opens submenus; left-click chooses a leaf;
right-click/ESC/click-outside dismiss; up/down move, right/RET open a submenu
or choose, left closes a submenu); returns the chosen leaf's INDEX, or nil if
dismissed.  Only meaningful while an `lrg' frame is live.  */)
  (Lisp_Object items, Lisp_Object x, Lisp_Object y)
{
  struct frame *f = lrg_any_frame ();
  GrlWindow *win;
  LrgMenuState st;
  int i, result = -1, settle = 2, ax, ay;
  bool done = false;

  if (f == NULL || !FRAME_LRG_P (f) || FRAME_LRG_SURFACE (f) == NULL)
    return Qnil;
  win = lrg_window_of_frame (f);
  if (win == NULL || !CONSP (items))
    return Qnil;

  memset (&st, 0, sizeof st);
  st.root = lrg_menu_build_items (items, &st.root_n);
  if (st.root == NULL)
    return Qnil;
  st.item_h  = FRAME_LINE_HEIGHT (f);
  st.pad_x   = FRAME_COLUMN_WIDTH (f);
  st.pad_y   = st.item_h / 4;
  st.arrow_w = st.item_h;

  ax = FIXNUMP (x) ? (int) XFIXNUM (x) : grl_input_get_mouse_x ();
  ay = FIXNUMP (y) ? (int) XFIXNUM (y) : grl_input_get_mouse_y ();

  st.panel[0].items = st.root;
  st.panel[0].n = st.root_n;
  st.panel[0].hovered = -1;
  lrg_menu_panel_layout (f, &st, &st.panel[0], ax, ay);
  st.depth = 1;
  for (i = 0; i < st.root_n; i++)   /* initial keyboard hover = 1st selectable */
    if (st.root[i].label != NULL && st.root[i].enabled)
      {
        st.panel[0].hovered = i;
        break;
      }

  lrg_active_menu = &st;
  grl_window_poll_events (win);   /* drain the click that opened the menu */

  /* Safety cap: ~12 ms/iteration, so ~8000 iterations is ~96 s.  Normal exit
     is via a click / RET / ESC / right-click / click-outside / window-close;
     the cap only guarantees the modal loop can never hard-hang Emacs.  */
  {
  int iters = 0;
  while (!done)
    {
      int mx, my, k, a, d;

      if (++iters > 8000 || !FRAME_LIVE_P (f))
        done = true;

      grl_window_poll_events (win);
      mx = grl_input_get_mouse_x ();
      my = grl_input_get_mouse_y ();

      /* Which open panel is the mouse over (deepest first -- children sit to
         the right of their parent)?  */
      a = -1;
      for (d = st.depth - 1; d >= 0; d--)
        {
          LrgMenuPanel *p = &st.panel[d];
          if (mx >= p->x && mx < p->x + p->w && my >= p->y && my < p->y + p->h)
            {
              a = d;
              break;
            }
        }
      if (a >= 0)
        {
          LrgMenuPanel *p = &st.panel[a];
          int row = lrg_menu_row_at (&st, p, my - p->y);
          if (row >= 0 && p->items[row].label != NULL && p->items[row].enabled)
            p->hovered = row;
          else
            p->hovered = -1;
          /* Close any panels deeper than this one; (re)open the hovered
             submenu as the child panel.  When the mouse is in the child this
             branch doesn't run for the parent, so the child stays open.  */
          st.depth = a + 1;
          if (p->hovered >= 0 && p->items[p->hovered].children != NULL
              && st.depth < LRG_MENU_MAX_DEPTH)
            lrg_menu_open_child (f, &st, a, p->hovered);
        }
      /* a < 0: mouse outside every panel -- leave the stack as is (so a
         submenu stays open while the pointer crosses a gap).  */

      /* Clicks (ignored for the first couple of frames so the press that
         opened the menu cannot be mis-read as a selection).  */
      if (settle > 0)
        settle--;
      else
        {
          if (grl_input_is_mouse_button_pressed (GRL_MOUSE_BUTTON_LEFT))
            {
              if (a >= 0)
                {
                  LrgMenuPanel *p = &st.panel[a];
                  if (p->hovered >= 0)
                    {
                      LrgMenuItem *it = &p->items[p->hovered];
                      if (it->children == NULL && it->enabled && it->index >= 0)
                        {
                          result = it->index;
                          done = true;
                        }
                    }
                }
              else
                done = true;            /* click outside dismisses */
            }
          if (grl_input_is_mouse_button_pressed (GRL_MOUSE_BUTTON_RIGHT))
            done = true;
        }

      /* Keyboard navigation acts on the deepest open panel.  */
      while ((k = grl_input_get_key_pressed ()) != 0)
        {
          LrgMenuPanel *p = &st.panel[st.depth - 1];
          if (k == GRL_KEY_ESCAPE)
            {
              if (st.depth > 1) st.depth--;
              else done = true;
            }
          else if (k == GRL_KEY_LEFT)
            {
              if (st.depth > 1) st.depth--;
            }
          else if (k == GRL_KEY_DOWN || k == GRL_KEY_UP)
            {
              int dir = (k == GRL_KEY_DOWN) ? 1 : -1;
              int j = (p->hovered < 0) ? (dir > 0 ? -1 : p->n) : p->hovered;
              int guard = p->n;
              while (guard-- > 0)
                {
                  j += dir;
                  if (j < 0) j = p->n - 1;
                  if (j >= p->n) j = 0;
                  if (p->items[j].label != NULL && p->items[j].enabled)
                    {
                      p->hovered = j;
                      break;
                    }
                }
            }
          else if (k == GRL_KEY_RIGHT || k == GRL_KEY_ENTER
                   || k == GRL_KEY_KP_ENTER)
            {
              if (p->hovered >= 0)
                {
                  LrgMenuItem *it = &p->items[p->hovered];
                  if (it->children != NULL
                      && st.depth < LRG_MENU_MAX_DEPTH)
                    {
                      int q;
                      lrg_menu_open_child (f, &st, st.depth - 1, p->hovered);
                      for (q = 0; q < st.panel[st.depth - 1].n; q++)
                        if (st.panel[st.depth - 1].items[q].label != NULL
                            && st.panel[st.depth - 1].items[q].enabled)
                          {
                            st.panel[st.depth - 1].hovered = q;
                            break;
                          }
                    }
                  else if (k != GRL_KEY_RIGHT && it->enabled && it->index >= 0)
                    {
                      result = it->index;
                      done = true;
                    }
                }
            }
        }

      if (grl_window_should_close (win))
        done = true;

      lrg_present_frame (f);          /* draws the frame + the menu overlay */
      if (!done)
        usleep (12000);               /* ~80 Hz; keep CPU idle while modal */
    }
  }

  lrg_active_menu = NULL;
  lrg_present_frame (f);              /* repaint without the menu */

  lrg_menu_free_items (st.root, st.root_n);

  return result >= 0 ? make_fixnum (result) : Qnil;
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
    lrg_sync_3d_panels (f, surf);
    for (pass = 0; pass < 2; pass++)
      {
        lrg_frame_surface_begin_frame (surf);
        lrg_frame_surface_clear (surf, bg);

        lrg_frame_surface_begin_content (surf);
        lrg_drawing = true;
        expose_frame (f, 0, 0, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f));
        lrg_drawing = false;

#ifdef HAVE_CMACS_LIBREGNUM
        lrg_paint_libregnum_views (f);
#endif

        /* Composite child-frame overlays so the capture matches the screen. */
        lrg_composite_child_frames (f, surf);

        lrg_frame_surface_end_content (surf);
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

/* ====================================================== 3D runtime control ==
   DEFUNs that drive the Lrg3DSurface at runtime (arrangement / environment /
   depth-of-field focus) + report the render mode.  Each no-ops gracefully when
   FRAME is not an lrg frame backed by a 3D surface.  */

/* Return F's 3D surface, or NULL if F is not a 3D-surface lrg frame.  */
static Lrg3DSurface *
lrg_3d_surface_of_frame (struct frame *f)
{
  LrgFrameSurface *s;

  if (!FRAME_LRG_P (f))
    return NULL;
  s = FRAME_LRG_SURFACE (f);
  return (s != NULL && LRG_IS_3D_SURFACE (s)) ? LRG_3D_SURFACE (s) : NULL;
}

DEFUN ("cmacs-lrg-3d-supported-p", Fcmacs_lrg_3d_supported_p,
       Scmacs_lrg_3d_supported_p, 0, 1, 0,
       doc: /* Return t if FRAME is an lrg frame rendered by the 3D surface.
FRAME defaults to the selected frame.  */)
  (Lisp_Object frame)
{
  return lrg_3d_surface_of_frame (decode_live_frame (frame)) != NULL ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-render-mode", Fcmacs_lrg_render_mode, Scmacs_lrg_render_mode,
       0, 1, 0,
       doc: /* Return FRAME's lrg render mode: "2d", "3d" or "3dvr", or nil if
FRAME is not an lrg frame.  FRAME defaults to the selected frame.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);

  if (!FRAME_LRG_P (f))
    return Qnil;
  return build_string (lrg_render_mode_to_string
                       ((LrgRenderMode) FRAME_LRG_OUTPUT (f)->render_mode));
}

DEFUN ("cmacs-lrg-set-render-mode", Fcmacs_lrg_set_render_mode,
       Scmacs_lrg_set_render_mode, 1, 1, 0,
       doc: /* Set the render MODE for the NEXT output_lrg frame created here.
MODE is "2d" (default), "3d" or "3dvr"; an optional ":ARRANGEMENT:ENVIRONMENT"
tail is ignored here (set those with the `cmacs-lrg-3d-*' commands).  This is
the runtime equivalent of the `--lrg=MODE' startup flag; `cmacs-lrg-attach'
uses it so a running Emacs (e.g. a daemon) can open a 3D lrg window on
demand.  Returns MODE.  */)
  (Lisp_Object mode)
{
  const char *m, *sep;
  ptrdiff_t headlen;

  CHECK_STRING (mode);
  m = SSDATA (mode);
  sep = strpbrk (m, ":,");
  headlen = sep ? sep - m : (ptrdiff_t) strlen (m);
  if (headlen == 4 && strncmp (m, "3dvr", 4) == 0)
    lrg_requested_render_mode = 2;
  else if (headlen == 2 && strncmp (m, "3d", 2) == 0)
    lrg_requested_render_mode = 1;
  else
    lrg_requested_render_mode = 0;
  return mode;
}

DEFUN ("cmacs-lrg-3d-set-arrangement", Fcmacs_lrg_3d_set_arrangement,
       Scmacs_lrg_3d_set_arrangement, 1, 2, 0,
       doc: /* Set FRAME's 3D panel ARRANGEMENT (a string id such as
"single-panel" or "per-window").  Returns t on success, nil if ARRANGEMENT is
unknown or FRAME is not a 3D lrg frame.  FRAME defaults to the selected frame.  */)
  (Lisp_Object arrangement, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  gboolean ok;

  CHECK_STRING (arrangement);
  if (s3 == NULL)
    return Qnil;
  block_input ();
  ok = lrg_3d_surface_set_arrangement_id (s3, SSDATA (arrangement));
  unblock_input ();
  if (ok)
    SET_FRAME_GARBAGED (f);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-3d-set-environment", Fcmacs_lrg_3d_set_environment,
       Scmacs_lrg_3d_set_environment, 1, 2, 0,
       doc: /* Set FRAME's 3D ENVIRONMENT (a string id such as "void",
"workshop" or "cockpit").  Returns t on success, nil if ENVIRONMENT is unknown
or FRAME is not a 3D lrg frame.  FRAME defaults to the selected frame.  */)
  (Lisp_Object environment, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  gboolean ok;

  CHECK_STRING (environment);
  if (s3 == NULL)
    return Qnil;
  block_input ();
  ok = lrg_3d_surface_set_environment_id (s3, SSDATA (environment));
  unblock_input ();
  if (ok)
    SET_FRAME_GARBAGED (f);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-3d-arrangement", Fcmacs_lrg_3d_arrangement,
       Scmacs_lrg_3d_arrangement, 0, 1, 0,
       doc: /* Return FRAME's current 3D arrangement id (a string), or nil.
FRAME defaults to the selected frame.  */)
  (Lisp_Object frame)
{
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (decode_live_frame (frame));
  const char *id = s3 != NULL ? lrg_3d_surface_get_arrangement_id (s3) : NULL;

  return id != NULL ? build_string (id) : Qnil;
}

DEFUN ("cmacs-lrg-3d-environment", Fcmacs_lrg_3d_environment,
       Scmacs_lrg_3d_environment, 0, 1, 0,
       doc: /* Return FRAME's current 3D environment id (a string), or nil.
FRAME defaults to the selected frame.  */)
  (Lisp_Object frame)
{
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (decode_live_frame (frame));
  const char *id = s3 != NULL ? lrg_3d_surface_get_environment_id (s3) : NULL;

  return id != NULL ? build_string (id) : Qnil;
}

DEFUN ("cmacs-lrg-3d-focus-window", Fcmacs_lrg_3d_focus_window,
       Scmacs_lrg_3d_focus_window, 0, 2, 0,
       doc: /* Focus WINDOW's 3D panel (depth-of-field): it becomes crisp/forward
and the others recede/dim.  WINDOW defaults to FRAME's selected window, FRAME to
the selected frame.  Only meaningful in the per-window / free arrangements.  */)
  (Lisp_Object window, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);

  if (s3 == NULL)
    return Qnil;
  if (NILP (window))
    window = FRAME_SELECTED_WINDOW (f);
  CHECK_LIVE_WINDOW (window);
  lrg_3d_surface_set_focus_window (s3, (guintptr) XWINDOW (window));
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-camera", Fcmacs_lrg_3d_camera, Scmacs_lrg_3d_camera,
       1, 3, 0,
       doc: /* Move the 3D camera.  OP is a string: "reset", "zoom-in",
"zoom-out", "orbit-left", "orbit-right", "orbit-up" or "orbit-down".  AMOUNT is
an optional magnitude (degrees for orbit, distance factor for zoom).  FRAME
defaults to the selected frame.  Returns t, or nil off a 3D lrg frame.  */)
  (Lisp_Object op, Lisp_Object amount, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  LrgSpatialCamera *cam;
  double amt;
  const char *o;

  CHECK_STRING (op);
  if (s3 == NULL)
    return Qnil;
  cam = lrg_3d_surface_get_camera (s3);
  if (cam == NULL)
    return Qnil;

  amt = NILP (amount) ? 0.0 : XFLOATINT (amount);
  o = SSDATA (op);
  block_input ();
  if (strcmp (o, "reset") == 0)
    lrg_spatial_camera_reset (cam);
  else if (strcmp (o, "zoom-in") == 0)
    lrg_spatial_camera_zoom (cam, amt > 0.0 ? (gfloat) amt : 0.85f);
  else if (strcmp (o, "zoom-out") == 0)
    lrg_spatial_camera_zoom (cam, amt > 0.0 ? (gfloat) amt : 1.1765f);
  else if (strcmp (o, "orbit-left") == 0)
    lrg_spatial_camera_orbit (cam, amt != 0.0 ? (gfloat) amt : -12.0f, 0.0f);
  else if (strcmp (o, "orbit-right") == 0)
    lrg_spatial_camera_orbit (cam, amt != 0.0 ? (gfloat) amt : 12.0f, 0.0f);
  else if (strcmp (o, "orbit-up") == 0)
    lrg_spatial_camera_orbit (cam, 0.0f, amt != 0.0 ? (gfloat) amt : 12.0f);
  else if (strcmp (o, "orbit-down") == 0)
    lrg_spatial_camera_orbit (cam, 0.0f, amt != 0.0 ? (gfloat) amt : -12.0f);
  unblock_input ();

  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-pick", Fcmacs_lrg_3d_pick, Scmacs_lrg_3d_pick, 2, 3, 0,
       doc: /* Map device pixel (X, Y) to a frame pixel via the surface's pick.
On a 3D lrg frame this ray-casts the pointer onto the panel under it and returns
the =(FX . FY)= frame pixel, or nil if it misses every panel; on a 2D lrg frame
it returns =(X . Y)= unchanged.  FRAME defaults to the selected frame.  */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  LrgFrameSurface *s;
  gfloat ox = 0.0f, oy = 0.0f;

  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  if (!FRAME_LRG_P (f))
    return Qnil;
  s = FRAME_LRG_SURFACE (f);
  if (s == NULL)
    return Qnil;
  if (!lrg_frame_surface_pick (s, (gfloat) XFIXNUM (x), (gfloat) XFIXNUM (y),
                               &ox, &oy))
    return Qnil;
  return Fcons (make_fixnum ((EMACS_INT) ox), make_fixnum ((EMACS_INT) oy));
}

DEFUN ("cmacs-lrg-3d-pick-panel", Fcmacs_lrg_3d_pick_panel,
       Scmacs_lrg_3d_pick_panel, 2, 3, 0,
       doc: /* Ray-cast device pixel (X, Y) and return =(FX FY KEY)= -- the frame
pixel plus the integer KEY of the panel hit -- or nil if the ray misses every
panel.  3D lrg frames only.  */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  gfloat ox = 0.0f, oy = 0.0f;
  guint64 key = 0;

  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  if (s3 == NULL)
    return Qnil;
  if (!lrg_3d_surface_pick_panel (s3, (gfloat) XFIXNUM (x), (gfloat) XFIXNUM (y),
                                  &ox, &oy, &key))
    return Qnil;
  return list3 (make_fixnum ((EMACS_INT) ox), make_fixnum ((EMACS_INT) oy),
                make_uint (key));
}

DEFUN ("cmacs-lrg-3d-focus-panel", Fcmacs_lrg_3d_focus_panel,
       Scmacs_lrg_3d_focus_panel, 0, 2, 0,
       doc: /* Bring WINDOW's 3D panel front-and-centre: set depth-of-field focus
to it (others dim) and fly the camera to a head-on framing of it.  WINDOW defaults
to FRAME's selected window, FRAME to the selected frame.  Returns t, or nil off a
3D lrg frame.  */)
  (Lisp_Object window, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);

  if (s3 == NULL)
    return Qnil;
  if (NILP (window))
    window = FRAME_SELECTED_WINDOW (f);
  CHECK_LIVE_WINDOW (window);
  lrg_3d_surface_focus_panel (s3, (guintptr) XWINDOW (window));
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-maximize-window", Fcmacs_lrg_3d_maximize_window,
       Scmacs_lrg_3d_maximize_window, 0, 2, 0,
       doc: /* Maximize WINDOW's 3D panel to a flat, 2D-like view: frame it head-on
and level (0-degree tilt), filling the viewport edge-to-edge -- as the 2D backend
/ PGTK would show it.  WINDOW defaults to FRAME's selected window (and falls back
to the whole-frame panel in single-panel mode).  Reset the camera
\(`cmacs-lrg-camera-reset' / =C-c 3 0=) to return to the 3D view.  Returns t, or
nil off a 3D lrg frame.  */)
  (Lisp_Object window, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  gboolean ok;

  if (s3 == NULL)
    return Qnil;
  if (NILP (window))
    window = FRAME_SELECTED_WINDOW (f);
  CHECK_LIVE_WINDOW (window);
  block_input ();
  ok = lrg_3d_surface_maximize_panel (s3, (guintptr) XWINDOW (window));
  unblock_input ();
  if (ok)
    SET_FRAME_GARBAGED (f);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-3d-orbit", Fcmacs_lrg_3d_orbit, Scmacs_lrg_3d_orbit, 0, 3, 0,
       doc: /* Orbit the 3D camera by DYAW degrees (azimuth) and DPITCH degrees
(elevation), eased.  Either defaults to 0.  FRAME defaults to the selected frame.
Returns t, or nil off a 3D lrg frame.  */)
  (Lisp_Object dyaw, Lisp_Object dpitch, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  LrgSpatialCamera *cam;

  if (s3 == NULL)
    return Qnil;
  cam = lrg_3d_surface_get_camera (s3);
  if (cam == NULL)
    return Qnil;
  block_input ();
  lrg_spatial_camera_orbit (cam,
                            NILP (dyaw) ? 0.0f : (gfloat) XFLOATINT (dyaw),
                            NILP (dpitch) ? 0.0f : (gfloat) XFLOATINT (dpitch));
  unblock_input ();
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-dolly", Fcmacs_lrg_3d_dolly, Scmacs_lrg_3d_dolly, 1, 2, 0,
       doc: /* Dolly the 3D camera by FACTOR (eye-to-target distance multiplier;
<1 moves toward the scene, >1 away).  FRAME defaults to the selected frame.
Returns t, or nil off a 3D lrg frame.  */)
  (Lisp_Object factor, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  LrgSpatialCamera *cam;

  if (s3 == NULL)
    return Qnil;
  cam = lrg_3d_surface_get_camera (s3);
  if (cam == NULL)
    return Qnil;
  block_input ();
  lrg_spatial_camera_zoom (cam, (gfloat) XFLOATINT (factor));
  unblock_input ();
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-move-panel", Fcmacs_lrg_3d_move_panel,
       Scmacs_lrg_3d_move_panel, 3, 5, 0,
       doc: /* Translate WINDOW's 3D panel by (DX, DY, DZ) world units and pin it
there.  WINDOW defaults to FRAME's selected window, FRAME to the selected frame.
Returns t, or nil off a 3D lrg frame.  */)
  (Lisp_Object window, Lisp_Object dx, Lisp_Object dy, Lisp_Object dz,
   Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);

  if (s3 == NULL)
    return Qnil;
  if (NILP (window))
    window = FRAME_SELECTED_WINDOW (f);
  CHECK_LIVE_WINDOW (window);
  lrg_3d_surface_move_panel (s3, (guintptr) XWINDOW (window),
                             (gfloat) XFLOATINT (dx),
                             (gfloat) XFLOATINT (dy),
                             NILP (dz) ? 0.0f : (gfloat) XFLOATINT (dz));
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-pin-panel", Fcmacs_lrg_3d_pin_panel,
       Scmacs_lrg_3d_pin_panel, 0, 2, 0,
       doc: /* Pin WINDOW's 3D panel in place (the arrangement no longer moves it).
WINDOW defaults to FRAME's selected window.  Returns t, or nil off a 3D lrg frame.  */)
  (Lisp_Object window, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);

  if (s3 == NULL)
    return Qnil;
  if (NILP (window))
    window = FRAME_SELECTED_WINDOW (f);
  CHECK_LIVE_WINDOW (window);
  lrg_3d_surface_pin_panel (s3, (guintptr) XWINDOW (window));
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-unpin-panel", Fcmacs_lrg_3d_unpin_panel,
       Scmacs_lrg_3d_unpin_panel, 0, 2, 0,
       doc: /* Release WINDOW's 3D panel back to automatic layout.  WINDOW defaults
to FRAME's selected window; with WINDOW t, unpin every panel.  Returns t, or nil
off a 3D lrg frame.  */)
  (Lisp_Object window, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);

  if (s3 == NULL)
    return Qnil;
  if (EQ (window, Qt))
    lrg_3d_surface_unpin_all (s3);
  else
    {
      if (NILP (window))
        window = FRAME_SELECTED_WINDOW (f);
      CHECK_LIVE_WINDOW (window);
      lrg_3d_surface_unpin_panel (s3, (guintptr) XWINDOW (window));
    }
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-load-gamepad-bindings",
       Fcmacs_lrg_3d_load_gamepad_bindings,
       Scmacs_lrg_3d_load_gamepad_bindings, 1, 1, 0,
       doc: /* Load a YAML gamepad / 6DOF binding map from FILE for the 3D camera.
The map binds the actions =orbit-yaw=, =orbit-pitch=, =pan-x=, =pan-y=,
=dolly-in= and =dolly-out= to device axes, replacing the built-in defaults
(right stick orbits, left stick pans, triggers dolly).  This is how a SpaceMouse
or another 6DOF/gamepad device is remapped without code changes.  Returns t on
success, nil on failure.  */)
  (Lisp_Object file)
{
  LrgInputMap *map;
  Lisp_Object encoded;
  g_autoptr (GError) err = NULL;
  gboolean ok;

  CHECK_STRING (file);
  map = lrg_gamepad_ensure_map ();
  encoded = ENCODE_FILE (file);
  ok = lrg_input_map_load_from_file (map, SSDATA (encoded), &err);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-3d-set-wall", Fcmacs_lrg_3d_set_wall, Scmacs_lrg_3d_set_wall,
       0, 1, 0,
       doc: /* Show BUFFER's libregnum 3D view on the cockpit back wall.
BUFFER should have a live libregnum view (a gnuseye / gobject-graph / editor /
CAD buffer); its rendered scene becomes the back wall under the `cockpit'
environment.  With BUFFER nil, clear the wall.  Returns BUFFER.  */)
  (Lisp_Object buffer)
{
  if (!NILP (buffer))
    CHECK_BUFFER (buffer);
  lrg_cockpit_wall_buffer = buffer;
  return buffer;
}

/* --- 3D workspace ring: off-screen render into a workspace panel ----------- */

DEFUN ("cmacs-lrg-3d-begin-offscreen", Fcmacs_lrg_3d_begin_offscreen,
       Scmacs_lrg_3d_begin_offscreen, 0, 1, 0,
       doc: /* Begin an off-screen workspace render on FRAME: suppress on-screen
presents until `cmacs-lrg-3d-end-offscreen'.  While suppressed, a (redisplay) of a
non-current workspace's window-config builds its glyph matrices without reaching
the screen or touching the live panels, so `cmacs-lrg-3d-render-into-panel' can
capture it.  Always pair with `cmacs-lrg-3d-end-offscreen' (use `unwind-protect').
FRAME defaults to the selected frame.  Returns t, or nil off a 3D lrg frame.  */)
  (Lisp_Object frame)
{
  if (lrg_3d_surface_of_frame (decode_live_frame (frame)) == NULL)
    return Qnil;
  lrg_present_suppressed = true;
  return Qt;
}

DEFUN ("cmacs-lrg-3d-end-offscreen", Fcmacs_lrg_3d_end_offscreen,
       Scmacs_lrg_3d_end_offscreen, 0, 1, 0,
       doc: /* End the off-screen render window begun by
`cmacs-lrg-3d-begin-offscreen': resume on-screen presents.  FRAME is accepted for
symmetry and ignored.  Returns t.  */)
  (Lisp_Object frame)
{
  (void) frame;
  lrg_present_suppressed = false;
  return Qt;
}

DEFUN ("cmacs-lrg-3d-render-into-panel", Fcmacs_lrg_3d_render_into_panel,
       Scmacs_lrg_3d_render_into_panel, 1, 2, 0,
       doc: /* Render FRAME's current flat content into workspace panel INDEX.
The caller installs a non-current workspace's window-config (and redisplays it,
typically inside a `cmacs-lrg-3d-begin/end-offscreen' pair) so FRAME's current
glyph matrices show that workspace; this captures them to the panel's own texture
without disturbing the live window panels.  The visible scene is re-composited
from the cached panels and is unchanged.  INDEX is a small workspace index.
Returns t, or nil off a 3D lrg frame.  */)
  (Lisp_Object index, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  guint64 key;

  CHECK_FIXNUM (index);
  if (s3 == NULL)
    return Qnil;
  key = LRG_WS_KEY (XFIXNUM (index));

  block_input ();
  {
    g_autoptr (GrlColor) bg = lrg_color (FRAME_LRG_BACKGROUND_COLOR (f));
    g_autoptr (GrlImage) img = NULL;
    LrgFrameSurface *surf = LRG_FRAME_SURFACE (s3);
    int w = FRAME_PIXEL_WIDTH (f);
    int h = FRAME_PIXEL_HEIGHT (f);

    /* Render the current content to the back buffer and read it back -- but do
       NOT sync the current window tree into the live panels (lrg_sync_3d_panels
       is deliberately skipped) and do NOT composite the off-screen content to
       the screen.  end_frame re-composites the live scene from the cached panel
       textures (which still hold the live workspace) and swaps, so the user sees
       no change; only this workspace's panel texture is refreshed.  */
    lrg_frame_surface_begin_frame (surf);
    lrg_frame_surface_clear (surf, bg);

    lrg_drawing = true;
    expose_frame (f, 0, 0, w, h);
    lrg_drawing = false;

    /* Flush the batched glyph quads so the readback sees them (mirrors the
       scissor flush in lrg_3d_surface_end_content).  */
    grl_draw_begin_scissor_mode (0, 0, w, h);
    grl_draw_end_scissor_mode ();

    img = grl_image_new_from_screen ();
    if (img != NULL)
      lrg_3d_surface_set_panel_image (s3, key, img);

    lrg_frame_surface_end_frame (surf);
  }
  unblock_input ();

  return Qt;
}

/* Shared body for the two workspace-panel placement DEFUNs (snap / eased).
   EASED selects lrg_3d_surface_place_panel_eased over the snapping variant.  */
static Lisp_Object
lrg_place_workspace_panel (Lisp_Object index, Lisp_Object px, Lisp_Object py,
                           Lisp_Object pz, Lisp_Object yaw, Lisp_Object w,
                           Lisp_Object h, Lisp_Object frame, bool eased)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  guint64 key;

  CHECK_FIXNUM (index);
  if (s3 == NULL)
    return Qnil;
  key = LRG_WS_KEY (XFIXNUM (index));
  block_input ();
  if (eased)
    lrg_3d_surface_place_panel_eased (s3, key,
                                      (gfloat) XFLOATINT (px),
                                      (gfloat) XFLOATINT (py),
                                      (gfloat) XFLOATINT (pz),
                                      (gfloat) XFLOATINT (yaw),
                                      (gfloat) XFLOATINT (w),
                                      (gfloat) XFLOATINT (h));
  else
    lrg_3d_surface_place_panel (s3, key,
                                (gfloat) XFLOATINT (px), (gfloat) XFLOATINT (py),
                                (gfloat) XFLOATINT (pz), (gfloat) XFLOATINT (yaw),
                                (gfloat) XFLOATINT (w), (gfloat) XFLOATINT (h));
  unblock_input ();
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-place-workspace-panel", Fcmacs_lrg_3d_place_workspace_panel,
       Scmacs_lrg_3d_place_workspace_panel, 7, 8, 0,
       doc: /* Place workspace panel INDEX at world (PX, PY, PZ), yaw YAW degrees,
size W x H world units, pinned there (the arrangement never moves it).  Creates
the panel if needed and snaps it into place.  Used to lay the workspace ring out
on a curved arc.  FRAME defaults to the selected frame.  Returns t, or nil off a
3D lrg frame.  */)
  (Lisp_Object index, Lisp_Object px, Lisp_Object py, Lisp_Object pz,
   Lisp_Object yaw, Lisp_Object w, Lisp_Object h, Lisp_Object frame)
{
  return lrg_place_workspace_panel (index, px, py, pz, yaw, w, h, frame, false);
}

DEFUN ("cmacs-lrg-3d-place-workspace-panel-eased",
       Fcmacs_lrg_3d_place_workspace_panel_eased,
       Scmacs_lrg_3d_place_workspace_panel_eased, 7, 8, 0,
       doc: /* Like `cmacs-lrg-3d-place-workspace-panel' but EASE the panel to the
new transform (a sliding carousel transition) instead of snapping.  */)
  (Lisp_Object index, Lisp_Object px, Lisp_Object py, Lisp_Object pz,
   Lisp_Object yaw, Lisp_Object w, Lisp_Object h, Lisp_Object frame)
{
  return lrg_place_workspace_panel (index, px, py, pz, yaw, w, h, frame, true);
}

DEFUN ("cmacs-lrg-3d-take-pending-workspace",
       Fcmacs_lrg_3d_take_pending_workspace,
       Scmacs_lrg_3d_take_pending_workspace, 0, 0, 0,
       doc: /* Return and clear the workspace index a Ctrl+double-left-click chose.
A click on a workspace panel records its index here; the workspace switcher polls
this from its command-loop timer and switches to the workspace, so the switch runs
safely in the command loop.  Returns the integer index, or nil if none pending.  */)
  (void)
{
  int idx = lrg_pending_ws_select;

  if (idx < 0)
    return Qnil;
  lrg_pending_ws_select = -1;
  return make_fixnum (idx);
}

DEFUN ("cmacs-lrg-3d-rotate-workspace-panel",
       Fcmacs_lrg_3d_rotate_workspace_panel,
       Scmacs_lrg_3d_rotate_workspace_panel, 2, 3, 0,
       doc: /* Rotate workspace panel INDEX by DYAW degrees about world Y and pin
it there.  FRAME defaults to the selected frame.  Returns t, or nil if the panel
does not exist / off a 3D lrg frame.  */)
  (Lisp_Object index, Lisp_Object dyaw, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  gboolean ok;

  CHECK_FIXNUM (index);
  if (s3 == NULL)
    return Qnil;
  block_input ();
  ok = lrg_3d_surface_rotate_panel (s3, LRG_WS_KEY (XFIXNUM (index)),
                                    (gfloat) XFLOATINT (dyaw));
  unblock_input ();
  if (ok)
    SET_FRAME_GARBAGED (f);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-3d-remove-workspace-panel",
       Fcmacs_lrg_3d_remove_workspace_panel,
       Scmacs_lrg_3d_remove_workspace_panel, 1, 2, 0,
       doc: /* Remove workspace panel INDEX (e.g. when its workspace is killed)
and forget its placement.  FRAME defaults to the selected frame.  Returns t, or
nil off a 3D lrg frame.  */)
  (Lisp_Object index, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);

  CHECK_FIXNUM (index);
  if (s3 == NULL)
    return Qnil;
  block_input ();
  lrg_3d_surface_remove_panel (s3, LRG_WS_KEY (XFIXNUM (index)));
  unblock_input ();
  SET_FRAME_GARBAGED (f);
  return Qt;
}

DEFUN ("cmacs-lrg-3d-workspace-panel-geometry",
       Fcmacs_lrg_3d_workspace_panel_geometry,
       Scmacs_lrg_3d_workspace_panel_geometry, 1, 2, 0,
       doc: /* Return workspace panel INDEX's transform as the list
=(PX PY PZ YAW W H)= (floats), or nil if the panel does not exist.  Used to
persist a user-adjusted workspace placement.  FRAME defaults to the selected
frame.  */)
  (Lisp_Object index, Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lrg3DSurface *s3 = lrg_3d_surface_of_frame (f);
  gfloat px, py, pz, yaw, w, h;

  CHECK_FIXNUM (index);
  if (s3 == NULL)
    return Qnil;
  if (!lrg_3d_surface_get_panel_geometry (s3, LRG_WS_KEY (XFIXNUM (index)),
                                          &px, &py, &pz, &yaw, &w, &h))
    return Qnil;
  return CALLN (Flist, make_float (px), make_float (py), make_float (pz),
                make_float (yaw), make_float (w), make_float (h));
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
  staticpro (&lrg_cockpit_wall_buffer);
  lrg_cockpit_wall_buffer = Qnil;
  defsubr (&Slrg_capture_screen);
  defsubr (&Slrg_popup_menu);
  defsubr (&Slrg_display_pixel_size);
  defsubr (&Slrg_set_clipboard);
  defsubr (&Slrg_get_clipboard);
  defsubr (&Scmacs_lrg_3d_supported_p);
  defsubr (&Scmacs_lrg_render_mode);
  defsubr (&Scmacs_lrg_set_render_mode);
  defsubr (&Scmacs_lrg_3d_set_arrangement);
  defsubr (&Scmacs_lrg_3d_set_environment);
  defsubr (&Scmacs_lrg_3d_arrangement);
  defsubr (&Scmacs_lrg_3d_environment);
  defsubr (&Scmacs_lrg_3d_focus_window);
  defsubr (&Scmacs_lrg_3d_camera);
  defsubr (&Scmacs_lrg_3d_pick);
  defsubr (&Scmacs_lrg_3d_pick_panel);
  defsubr (&Scmacs_lrg_3d_focus_panel);
  defsubr (&Scmacs_lrg_3d_maximize_window);
  defsubr (&Scmacs_lrg_3d_orbit);
  defsubr (&Scmacs_lrg_3d_dolly);
  defsubr (&Scmacs_lrg_3d_move_panel);
  defsubr (&Scmacs_lrg_3d_pin_panel);
  defsubr (&Scmacs_lrg_3d_unpin_panel);
  defsubr (&Scmacs_lrg_3d_load_gamepad_bindings);
  defsubr (&Scmacs_lrg_3d_set_wall);
  defsubr (&Scmacs_lrg_3d_begin_offscreen);
  defsubr (&Scmacs_lrg_3d_end_offscreen);
  defsubr (&Scmacs_lrg_3d_render_into_panel);
  defsubr (&Scmacs_lrg_3d_place_workspace_panel);
  defsubr (&Scmacs_lrg_3d_place_workspace_panel_eased);
  defsubr (&Scmacs_lrg_3d_rotate_workspace_panel);
  defsubr (&Scmacs_lrg_3d_remove_workspace_panel);
  defsubr (&Scmacs_lrg_3d_workspace_panel_geometry);
  defsubr (&Scmacs_lrg_3d_take_pending_workspace);
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
