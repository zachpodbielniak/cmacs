/* cmacs-video-overlay.c --- Cairo paint hook for embedded video.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Two passes per frame:
 *
 *  1. Per-frame standalone list: streams anchored to FRAME at a fixed
 *     rect via cmacs-video-attach-frame.  Used by cmacs-video-mode
 *     buffers where the whole window body is the video surface.
 *
 *  2. Per-window walk: for each leaf window of FRAME, read the
 *     buffer-local `cmacs-video--streams' list.  Each entry is a
 *     plist (:handle N :marker M :w W :h H).  Look up the stream
 *     handle, ask `pos_visible_p' for the marker's pixel coords,
 *     translate to frame-absolute, then blit the front buffer.
 *
 * pgtk-only: bails out cleanly on non-pgtk frames so cmacs builds
 * without --with-pgtk still link.
 */

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "cmacs-video-overlay.h"
#include "cmacs-video-registry.h"
#include "cmacs-video-stream.h"

#include "lisp.h"
#include "frame.h"
#include "buffer.h"
#include "window.h"

#ifdef HAVE_PGTK
#include "pgtkterm.h"
#include <cairo.h>

/* ---------------- Symbol cache ---------------- */

static Lisp_Object Qcmacs_video__streams;
static Lisp_Object QChandle, QCmarker, QCw, QCh;

void
cmacs_video_overlay_init_symbols (void)
{
  Qcmacs_video__streams = intern_c_string ("cmacs-video--streams");
  QChandle              = intern_c_string (":handle");
  QCmarker              = intern_c_string (":marker");
  QCw                   = intern_c_string (":w");
  QCh                   = intern_c_string (":h");
  staticpro (&Qcmacs_video__streams);
  staticpro (&QChandle);
  staticpro (&QCmarker);
  staticpro (&QCw);
  staticpro (&QCh);
}

/* find_symbol_value-style safe read: returns Qunbound if VAR is not
 * yet defvar'd (paint hook runs even before cmacs-video.el loads). */
static Lisp_Object
cmacs_video__safe_blv (Lisp_Object var, Lisp_Object buffer)
{
  if (NILP (Fboundp (var)))
    return Qunbound;
  return buffer_local_value (var, buffer);
}

/* Paint one stream at frame-absolute (px, py) with size (pw, ph). */
static void
cmacs_video__paint_one (cairo_t *cr, CmacsVideoStream *s,
                        int px, int py, int pw, int ph)
{
  if (!s || pw <= 0 || ph <= 0)
    return;
  g_mutex_lock (&s->frame_mtx);
  cairo_surface_t *front = cmacs_video_stream_peek_front_locked (s);
  int fw = s->frame_w, fh = s->frame_h;
  if (front && fw > 0 && fh > 0)
    {
      cairo_save (cr);
      cairo_translate (cr, px, py);
      cairo_scale    (cr, (double)pw / fw, (double)ph / fh);
      cairo_set_source_surface (cr, front, 0, 0);
      /* Use NEAREST when upscaling > 2x for less blur; BILINEAR
       * default is fine for typical 1:1 or slight scale.  Cairo's
       * default already does bilinear for source. */
      cairo_paint (cr);
      cairo_restore (cr);
    }
  g_mutex_unlock (&s->frame_mtx);
}

/* ---------------- Standalone pass ---------------- */

static void
cmacs_video__paint_standalone (struct frame *f, cairo_t *cr)
{
  GSList *streams = cmacs_video_registry_frame_streams (f);
  for (GSList *l = streams; l; l = l->next)
    {
      CmacsVideoStream *s = l->data;
      if (!s || s->state == CMACS_VIDEO_STATE_CLOSED)
        continue;
      if (s->standalone_frame != f)
        continue;
      cmacs_video__paint_one (cr, s,
                              s->standalone_x, s->standalone_y,
                              s->standalone_w, s->standalone_h);
    }
  g_slist_free (streams);
}

/* ---------------- Window-walk (buffer-anchored) pass ---------------- */

static void
cmacs_video__paint_window (struct frame *f, struct window *w, cairo_t *cr)
{
  if (!WINDOW_LEAF_P (w))
    return;
  Lisp_Object buffer = w->contents;
  if (!BUFFERP (buffer))
    return;

  Lisp_Object streams_var = cmacs_video__safe_blv (Qcmacs_video__streams,
                                                   buffer);
  if (BASE_EQ (streams_var, Qunbound) || NILP (streams_var))
    return;

  int text_area_left = window_box_left (w, TEXT_AREA);
  int text_area_top  = WINDOW_TOP_EDGE_Y (w);

  /* Clip to the window box.  Wraps the entire iteration so each
   * stream's blit cannot bleed past window borders. */
  cairo_save (cr);
  cairo_rectangle (cr,
                   WINDOW_BOX_LEFT_PIXEL_EDGE (w),
                   WINDOW_TOP_PIXEL_EDGE (w),
                   WINDOW_PIXEL_WIDTH (w),
                   WINDOW_PIXEL_HEIGHT (w));
  cairo_clip (cr);

  Lisp_Object tail;
  for (tail = streams_var; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object entry = XCAR (tail);
      if (!CONSP (entry))
        continue;
      Lisp_Object hval = Fplist_get (entry, QChandle, Qnil);
      Lisp_Object mval = Fplist_get (entry, QCmarker, Qnil);
      Lisp_Object wval = Fplist_get (entry, QCw,      Qnil);
      Lisp_Object hpx  = Fplist_get (entry, QCh,      Qnil);

      if (!INTEGERP (hval) || !MARKERP (mval))
        continue;
      EMACS_INT handle = XFIXNUM (hval);
      CmacsVideoStream *s = cmacs_video_registry_lookup ((uint64_t) handle);
      if (!s || s->state == CMACS_VIDEO_STATE_CLOSED)
        continue;

      /* Stream is buffer-anchored to a DIFFERENT buffer? skip. */
      {
        Lisp_Object anchor = cmacs_video_stream_anchor_buffer (s);
        if (BUFFERP (anchor) && !BASE_EQ (anchor, buffer))
          continue;
      }

      ptrdiff_t marker_pos = marker_position (mval);

      int x = 0, y = 0, rtop = 0, rbot = 0, rowh = 0, vpos = 0;
      bool visible = pos_visible_p (w, marker_pos,
                                    &x, &y, &rtop, &rbot, &rowh, &vpos);
      if (!visible)
        continue;

      int pw = INTEGERP (wval) ? (int) XFIXNUM (wval) : s->target_w;
      int ph = INTEGERP (hpx)  ? (int) XFIXNUM (hpx)  : s->target_h;

      int px = text_area_left + x;
      int py = text_area_top  + y;

      cmacs_video__paint_one (cr, s, px, py, pw, ph);
    }

  cairo_restore (cr);
}

static void
cmacs_video__walk (struct frame *f, struct window *w, cairo_t *cr)
{
  if (!w)
    return;
  if (WINDOW_LEAF_P (w))
    cmacs_video__paint_window (f, w, cr);
  else
    {
      if (!NILP (w->contents) && WINDOWP (w->contents))
        cmacs_video__walk (f, XWINDOW (w->contents), cr);
      if (!NILP (w->next) && WINDOWP (w->next))
        cmacs_video__walk (f, XWINDOW (w->next), cr);
    }
}

void
cmacs_video_overlay_paint (struct frame *f, cairo_t *cr)
{
  if (!f || !cr)
    return;
  if (!FRAME_PGTK_P (f))
    return;
  cmacs_video__paint_standalone (f, cr);
  Lisp_Object root = FRAME_ROOT_WINDOW (f);
  if (WINDOWP (root))
    cmacs_video__walk (f, XWINDOW (root), cr);
}

#else  /* HAVE_PGTK */

void
cmacs_video_overlay_init_symbols (void) {}

void
cmacs_video_overlay_paint (struct frame *f, cairo_t *cr)
{
  (void) f;
  (void) cr;
}

#endif /* HAVE_PGTK */

#endif /* HAVE_CMACS_VIDEO */
