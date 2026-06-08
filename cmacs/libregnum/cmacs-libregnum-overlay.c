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
#include "cmacs-libregnum-render.h"

#include <cairo.h>

/* Draw directory (and selected-node) names projected onto the view's
 * blit.  PX/PY/PW/PH are the window's frame-pixel rect, VW/VH the view
 * render size.  Projection returns view-local pixels; we map them into
 * the window rect (no Y flip -- the projection already matches the
 * displayed, un-flipped orientation). */
/* Draw persistent map labels (country/region names), but only once the
 * camera has zoomed in, so a full-globe view is not buried in text. */
static void
cmacs_libregnum__draw_map_labels (cairo_t *cr, CmacsLibregnumView *v,
                                  int px, int py, int pw, int ph,
                                  int vw, int vh)
{
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  guint nc = cmacs_libregnum_render_ctx_map_label_count (ctx);
  if (nc == 0) return;
  if (cmacs_libregnum_render_ctx_camera_distance (ctx) > 13.0) return;
  double sxv = (double) pw / vw, syv = (double) ph / vh;
  /* Drop the name just below the flag (if any) so the flag does not cover
   * it.  Flags are zoom-scaled small, so keep this gap modest. */
  double yoff = (cmacs_libregnum_render_ctx_billboard_count (ctx) > 0)
                ? ph * 0.018 + 4.0 : 10.0;
  cairo_save (cr);
  cairo_select_font_face (cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                          CAIRO_FONT_WEIGHT_BOLD);
  cairo_set_font_size (cr, 11.0);
  for (guint i = 0; i < nc; i++)
    {
      const char *text = NULL;
      double lx = 0, ly = 0;
      guint8 r = 255, g = 255, b = 255;
      if (!cmacs_libregnum_render_ctx_map_label_at (ctx, i, vw, vh, &lx, &ly,
                                                    &text, &r, &g, &b))
        continue;
      if (!text || !text[0]) continue;
      double fx = px + lx * sxv;
      double fy = py + ly * syv + yoff;
      cairo_text_extents_t ext;
      cairo_text_extents (cr, text, &ext);
      fx -= ext.width * 0.5;
      cairo_set_source_rgba (cr, 0.0, 0.0, 0.0, 0.8);
      cairo_move_to (cr, fx + 1.0, fy + 1.0);
      cairo_show_text (cr, text);
      cairo_set_source_rgba (cr, r / 255.0, g / 255.0, b / 255.0, 0.95);
      cairo_move_to (cr, fx, fy);
      cairo_show_text (cr, text);
    }
  cairo_restore (cr);
}

static void
cmacs_libregnum__draw_labels (cairo_t *cr, CmacsLibregnumView *v,
                              int px, int py, int pw, int ph,
                              int vw, int vh)
{
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  guint nc = cmacs_libregnum_render_ctx_node_count (ctx);
  if (nc == 0) return;
  gint sel = cmacs_libregnum_render_ctx_get_selected (ctx);
  gint hov = cmacs_libregnum_render_ctx_get_hovered (ctx);
  double sxv = (double) pw / vw;
  double syv = (double) ph / vh;

  cairo_save (cr);
  cairo_select_font_face (cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                          CAIRO_FONT_WEIGHT_NORMAL);
  cairo_set_font_size (cr, 12.0);
  for (guint i = 0; i < nc; i++)
    {
      const char *name = NULL;
      gboolean is_dir = FALSE;
      double lx = 0, ly = 0;
      if (!cmacs_libregnum_render_ctx_label_at (ctx, i, vw, vh, &lx, &ly,
                                                &name, &is_dir))
        continue;
      gboolean selected = ((gint) i == sel);
      gboolean hovered  = ((gint) i == hov);
      /* Per-node label policy.  LEGACY keeps the original behaviour
       * (label directories + the selected node); explicit modes let a
       * scene builder (e.g. the gnuseye globe) label per node. */
      switch (cmacs_libregnum_render_ctx_get_node_label_mode (ctx, i))
        {
        case CMACS_LIBREGNUM_LABEL_NEVER:
          continue;
        case CMACS_LIBREGNUM_LABEL_SELECTED:
          if (!selected) continue;
          break;
        case CMACS_LIBREGNUM_LABEL_HOVER:
          if (!selected && !hovered) continue;
          break;
        case CMACS_LIBREGNUM_LABEL_ALWAYS:
          break;
        default: /* CMACS_LIBREGNUM_LABEL_LEGACY */
          if (!is_dir && !selected) continue;
          break;
        }
      if (!name || !name[0]) continue;

      double fx = px + lx * sxv;
      double fy = py + ly * syv;
      /* Centre horizontally on the node. */
      cairo_text_extents_t ext;
      cairo_text_extents (cr, name, &ext);
      fx -= ext.width * 0.5;

      /* Shadow for contrast, then the label. */
      cairo_set_source_rgba (cr, 0.0, 0.0, 0.0, 0.7);
      cairo_move_to (cr, fx + 1.0, fy + 1.0);
      cairo_show_text (cr, name);
      if (selected)
        cairo_set_source_rgba (cr, 1.0, 0.92, 0.47, 1.0);
      else
        cairo_set_source_rgba (cr, 0.95, 0.95, 1.0, 0.95);
      cairo_move_to (cr, fx, fy);
      cairo_show_text (cr, name);
    }
  cairo_restore (cr);
}

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
                      /* Fit the view's vw x vh surface into the window's
                       * pw x ph text area. */
                      cairo_scale (cr, (double) pw / vw, (double) ph / vh);
                      /* The surface holds the GL framebuffer bottom-up
                       * (glReadPixels origin is lower-left).  Flip it
                       * here so the read path needs no CPU row-flip:
                       * move the origin to the bottom edge, then mirror
                       * the Y axis. */
                      cairo_translate (cr, 0, vh);
                      cairo_scale (cr, 1.0, -1.0);
                      cairo_set_source_surface (cr, s, 0, 0);
                      cairo_paint (cr);
                      cairo_restore (cr);
                    }
                  cmacs_libregnum_view_unlock_surface (v);
                  /* Record that this view is on-screen this frame so
                   * the animation clock keeps driving it (and stops
                   * when the buffer is no longer shown). */
                  cmacs_libregnum_view_mark_painted (v);

                  /* In-scene labels: project each directory node (and
                   * the selected node) to its on-screen position and
                   * draw its name in cairo, on top of the blit.  Pure
                   * C + cairo -- no Lisp re-entry.  Files stay unlabeled
                   * to avoid clutter (they label when selected). */
                  cmacs_libregnum__draw_map_labels (cr, v, px, py, pw, ph,
                                                    vw, vh);
                  cmacs_libregnum__draw_labels (cr, v, px, py, pw, ph,
                                                vw, vh);
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
