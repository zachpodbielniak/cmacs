/* cmacs-libregnum-overlay.c --- pgtk_handle_draw blit hook.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Called from src/pgtkterm.c's pgtk_handle_draw after cmacs-video
 * and cmacs-audio overlays.  If the selected window of FRAME shows
 * a buffer that has a libregnum view, we blit the view's BGRA
 * surface across the entire text area (dedicated-major-mode model:
 * the buffer IS the scene). */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "frame.h"
#include "window.h"
#include "buffer.h"
#include "cmacs-libregnum.h"

#include <cairo.h>

void
cmacs_libregnum_overlay_paint (struct frame *f, cairo_t *cr)
{
  if (!f || !cr) return;

  /* For every window on this frame, check if its buffer is a
   * libregnum buffer; if so, blit the view's BGRA surface across
   * the window's text area. */
  Lisp_Object frame;
  XSETFRAME (frame, f);
  Lisp_Object root = Fframe_root_window (frame);
  Lisp_Object windows = Fwindow_list (frame, Qnil, root);

  Lisp_Object tail = windows;
  FOR_EACH_TAIL_SAFE (tail)
    {
      Lisp_Object w = XCAR (tail);
      if (!WINDOWP (w)) continue;
      Lisp_Object buf = Fwindow_buffer (w);
      if (!BUFFERP (buf)) continue;
      CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buf);
      if (!v) continue;

      /* Read window pixel bounds. */
      int px = WINDOW_LEFT_PIXEL_EDGE (XWINDOW (w));
      int py = WINDOW_TOP_PIXEL_EDGE  (XWINDOW (w));
      int pw = WINDOW_PIXEL_WIDTH      (XWINDOW (w));
      int ph = WINDOW_PIXEL_HEIGHT     (XWINDOW (w));

      /* If the view's intrinsic size differs from the window's
       * pixel size, we'd ideally resize the view; for v1 just
       * scale via cairo. */
      int vw, vh;
      cmacs_libregnum_view_get_size (v, &vw, &vh);
      if (vw <= 0 || vh <= 0) continue;

      cairo_surface_t *s = cmacs_libregnum_view_lock_surface (v);
      if (s)
        {
          cairo_save (cr);
          cairo_translate (cr, px, py);
          if (vw != pw || vh != ph)
            cairo_scale (cr, (double) pw / vw, (double) ph / vh);
          cairo_set_source_surface (cr, s, 0, 0);
          cairo_paint (cr);
          cairo_restore (cr);
        }
      cmacs_libregnum_view_unlock_surface (v);
    }
}

#endif /* HAVE_CMACS_LIBREGNUM */
