/* cmacs-libregnum-overlay.c --- pgtk_handle_draw blit hook.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Called from src/pgtkterm.c's pgtk_handle_draw after cmacs-video
 * and cmacs-audio overlays.  For every leaf window on FRAME whose
 * buffer has an attached libregnum view, we blit the view's BGRA
 * surface across the window's text area.
 *
 * CRITICAL: this hook runs INSIDE a GTK draw signal handler.  We
 * must NOT call any Lisp `F*` accessor that can xsignal -- e.g.
 * Fframe_root_window does CHECK_LIVE_FRAME, Fwindow_list does
 * CHECK_WINDOW and may error on cross-frame mismatch.  An xsignal
 * here longjmps through GLib's signal_emit_unlocked_R, bypassing
 * its emission_pop cleanup and leaving the global emission_head
 * pointing at freed stack memory.  The next signal emission
 * anywhere crashes in emission_find.
 *
 * Therefore: walk the frame's window tree directly via the C
 * struct (frame->root_window, win->contents, win->next), and
 * fast-path bail when the view registry is empty so the common
 * case (no libregnum buffer ever opened) is a true no-op. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "frame.h"
#include "window.h"
#include "buffer.h"
#include "cmacs-libregnum.h"

#include <cairo.h>

static void
cmacs_libregnum__walk_windows (struct frame *f, cairo_t *cr, Lisp_Object w)
{
  while (!NILP (w) && WINDOWP (w))
    {
      struct window *win = XWINDOW (w);
      Lisp_Object contents = win->contents;

      if (WINDOWP (contents))
        {
          /* Internal window node: recurse into its child tree. */
          cmacs_libregnum__walk_windows (f, cr, contents);
        }
      else if (BUFFERP (contents))
        {
          CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (contents);
          if (v)
            {
              int px = WINDOW_LEFT_PIXEL_EDGE (win);
              int py = WINDOW_TOP_PIXEL_EDGE  (win);
              int pw = WINDOW_PIXEL_WIDTH     (win);
              int ph = WINDOW_PIXEL_HEIGHT    (win);
              int vw = 0, vh = 0;
              cmacs_libregnum_view_get_size (v, &vw, &vh);
              if (vw > 0 && vh > 0)
                {
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
        }
      w = win->next;
    }
}

void
cmacs_libregnum_overlay_paint (struct frame *f, cairo_t *cr)
{
  if (!f || !cr) return;
  /* Fast path: no view has ever been attached on this cmacs.
   * Avoids any Lisp re-entry on every redisplay of every frame. */
  if (cmacs_libregnum_view_registry_empty_p ()) return;
  if (!FRAME_LIVE_P (f)) return;

  cmacs_libregnum__walk_windows (f, cr, f->root_window);
}

#endif /* HAVE_CMACS_LIBREGNUM */
