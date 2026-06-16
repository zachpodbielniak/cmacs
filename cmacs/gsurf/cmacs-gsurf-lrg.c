/* cmacs-gsurf-lrg.c --- gsurf under the libregnum (--lrg) display backend.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * When Emacs runs as `emacs --lrg' there is no GTK widget tree to embed a
 * WebKitGTK widget into, so gsurf uses its libregnum backend: the page is
 * rendered to a GrlTexture (cmacs/../deps/gsurf/src/backend/lrg) which this
 * file hands to lrgterm to composite into the buffer's window rectangle, and
 * raylib input that lrgterm receives is forwarded back into the page here.
 *
 * This translation unit is GTK-free and libregnum-free: it talks to the page
 * only through the gsurf LRG view API (GsurfLrgView) and returns the texture
 * as an opaque void* (lrgterm, which links libregnum, casts it).  The per-
 * buffer view registry + focus state live in cmacs-gsurf-view.c; this file
 * reaches them through the internal accessors. */

#include <config.h>

#ifdef HAVE_CMACS_GSURF_LRG

#include "lisp.h"
#include "frame.h"
#include "window.h"
#include "buffer.h"
#include "cmacs-gsurf.h"
#include "cmacs-gsurf-internal.h"

#include <gsurf/backend/lrg/gsurf-lrg-view.h>

/* Pixels of page scroll per unit of lrgterm wheel delta. */
#define CMACS_GSURF_LRG_SCROLL_STEP 40.0

/* ── Composite ──────────────────────────────────────────────────────── */

void *
cmacs_gsurf_lrg_texture_for_window (Lisp_Object buffer, int w, int h,
                                    int *out_tw, int *out_th)
{
  CmacsGsurfView *v = cmacs_gsurf_view_for_buffer (buffer);
  GsurfView *gv;
  GsurfLrgView *lv;

  if (out_tw) *out_tw = 0;
  if (out_th) *out_th = 0;

  if (v == NULL || !cmacs_gsurf_view_is_lrg (v))
    return NULL;
  gv = cmacs_gsurf_view_gsurf (v);
  if (gv == NULL)
    return NULL;
  lv = GSURF_LRG_VIEW (gv);

  /* Keep the page laid out at the window-body size, then read back this
     frame.  get_texture performs the GPU upload and must run here (lrgterm's
     present owns the GL context). */
  if (w > 0 && h > 0)
    gsurf_lrg_view_resize (lv, w, h, 1.0);
  gsurf_lrg_view_capture (lv);
  return gsurf_lrg_view_get_texture (lv, out_tw, out_th);
}

/* ── Window hit-testing ─────────────────────────────────────────────── */

/* Find the leaf window in F under frame pixel (X,Y) whose buffer has a
   gsurf-lrg view; fill its body rect.  Recurses over the window tree like
   lrg_paint_libregnum_window. */
static CmacsGsurfView *
lrg_view_at_pixel (Lisp_Object w, int x, int y,
                   int *bx, int *by, int *bw, int *bh)
{
  while (!NILP (w) && WINDOWP (w))
    {
      struct window *win = XWINDOW (w);
      Lisp_Object contents = win->contents;

      if (WINDOWP (contents))
        {
          CmacsGsurfView *v = lrg_view_at_pixel (contents, x, y, bx, by, bw, bh);
          if (v != NULL)
            return v;
        }
      else if (BUFFERP (contents))
        {
          int px = WINDOW_LEFT_PIXEL_EDGE (win);
          int py = WINDOW_TOP_PIXEL_EDGE  (win);
          int pw = WINDOW_PIXEL_WIDTH      (win);
          int ph = WINDOW_PIXEL_HEIGHT     (win);

          if (x >= px && x < px + pw && y >= py && y < py + ph)
            {
              CmacsGsurfView *v = cmacs_gsurf_view_for_buffer (contents);
              if (v != NULL && cmacs_gsurf_view_is_lrg (v))
                {
                  *bx = px; *by = py; *bw = pw; *bh = ph;
                  return v;
                }
            }
        }
      w = win->next;
    }
  return NULL;
}

/* Map a frame pixel inside a window body to page-local device pixels. */
static void
lrg_page_coords (int x, int y, int bx, int by, int bw, int bh,
                 int *px, int *py)
{
  int lx = x - bx;
  int ly = y - by;
  if (lx < 0) lx = 0;
  if (ly < 0) ly = 0;
  if (bw > 0 && lx > bw - 1) lx = bw - 1;
  if (bh > 0 && ly > bh - 1) ly = bh - 1;
  *px = lx;
  *py = ly;
}

/* ── Pointer input ──────────────────────────────────────────────────── */

bool
cmacs_gsurf_lrg_handle_motion (struct frame *f, double x, double y)
{
  int bx, by, bw, bh, px, py;
  CmacsGsurfView *v;

  if (f == NULL || !FRAME_LIVE_P (f))
    return false;
  v = lrg_view_at_pixel (f->root_window, (int) x, (int) y, &bx, &by, &bw, &bh);
  if (v == NULL)
    return false;

  lrg_page_coords ((int) x, (int) y, bx, by, bw, bh, &px, &py);
  gsurf_lrg_view_send_motion (GSURF_LRG_VIEW (cmacs_gsurf_view_gsurf (v)),
                              px, py, GSURF_MOD_NONE);
  return true;
}

bool
cmacs_gsurf_lrg_handle_button (struct frame *f, int button, int press,
                               double x, double y)
{
  int bx, by, bw, bh, px, py;
  CmacsGsurfView *v;

  if (f == NULL || !FRAME_LIVE_P (f))
    return false;
  v = lrg_view_at_pixel (f->root_window, (int) x, (int) y, &bx, &by, &bw, &bh);
  if (v == NULL)
    return false;

  lrg_page_coords ((int) x, (int) y, bx, by, bw, bh, &px, &py);

  /* A click focuses the page so subsequent keys type into it. */
  if (press)
    cmacs_gsurf_view_focus_page (v);

  gsurf_lrg_view_send_button (GSURF_LRG_VIEW (cmacs_gsurf_view_gsurf (v)),
                              px, py, (guint) button, press != 0,
                              GSURF_MOD_NONE);
  return true;
}

bool
cmacs_gsurf_lrg_handle_scroll (struct frame *f, double dx, double dy,
                               double x, double y)
{
  int bx, by, bw, bh, px, py;
  CmacsGsurfView *v;

  if (f == NULL || !FRAME_LIVE_P (f))
    return false;
  v = lrg_view_at_pixel (f->root_window, (int) x, (int) y, &bx, &by, &bw, &bh);
  if (v == NULL)
    return false;

  lrg_page_coords ((int) x, (int) y, bx, by, bw, bh, &px, &py);
  gsurf_lrg_view_send_axis (GSURF_LRG_VIEW (cmacs_gsurf_view_gsurf (v)),
                            px, py,
                            dx * CMACS_GSURF_LRG_SCROLL_STEP,
                            dy * CMACS_GSURF_LRG_SCROLL_STEP,
                            GSURF_MOD_NONE);
  return true;
}

bool
cmacs_gsurf_lrg_over_view (struct frame *f, double x, double y)
{
  int bx, by, bw, bh;
  if (f == NULL || !FRAME_LIVE_P (f))
    return false;
  return lrg_view_at_pixel (f->root_window, (int) x, (int) y,
                            &bx, &by, &bw, &bh) != NULL;
}

/* ── Keyboard ───────────────────────────────────────────────────────── */

/* Convert an Emacs modifier bitmask (ctrl_modifier, ...) to a GsurfKeyMod. */
static guint
emacs_mods_to_gsurf (int mods)
{
  guint g = GSURF_MOD_NONE;
  if (mods & ctrl_modifier)  g |= GSURF_MOD_CTRL;
  if (mods & meta_modifier)  g |= GSURF_MOD_ALT;
  if (mods & shift_modifier) g |= GSURF_MOD_SHIFT;
  if (mods & super_modifier) g |= GSURF_MOD_SUPER;
  return g;
}

bool
cmacs_gsurf_lrg_page_focused_p (struct frame *f)
{
  (void) f;
  /* A page is focused only between an explicit focus (click / `i' / `RET' /
     `f') and a release (Escape / window switch / cmacs-gsurf-release-focus),
     so routing all keys to it while that holds is correct. */
  return cmacs_gsurf_lrg_focused_view () != NULL;
}

bool
cmacs_gsurf_lrg_handle_key (struct frame *f, int keysym, int unichar, int mods)
{
  CmacsGsurfView *v = cmacs_gsurf_lrg_focused_view ();
  GsurfLrgView *lv;
  guint sym, gmods;

  (void) f;
  if (v == NULL)
    return false;
  lv = GSURF_LRG_VIEW (cmacs_gsurf_view_gsurf (v));
  gmods = emacs_mods_to_gsurf (mods);

  /* Printable input arrives as a Unicode codepoint; for Latin-1 the keysym
     equals the codepoint, above that GDK uses 0x01000000|codepoint.  Non-text
     keys carry an explicit X keysym. */
  if (unichar > 0)
    sym = (unichar <= 0xFF) ? (guint) unichar : (0x01000000u | (guint) unichar);
  else
    sym = (guint) keysym;

  if (sym != 0)
    {
      gsurf_lrg_view_send_key (lv, sym, 0, gmods, TRUE);
      gsurf_lrg_view_send_key (lv, sym, 0, gmods, FALSE);
    }
  return true;
}

#endif /* HAVE_CMACS_GSURF_LRG */
