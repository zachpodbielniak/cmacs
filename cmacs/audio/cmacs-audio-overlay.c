/* cmacs-audio-overlay.c --- Cairo paint hook for audio waveforms.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The waveform overlay is much lighter than the video overlay: there
 * is no per-frame data motion.  We simply paint the cached SVG-rendered
 * surface (if present) at the stream's anchor point.  Most actual
 * waveform rendering happens in Elisp via `(create-image SVG 'svg t)';
 * this C path is reserved for standalone-mode buffers where we have
 * direct cairo access.
 *
 * For the common case (#+BEGIN_AUDIO blocks inside an org buffer),
 * the Elisp layer puts an inline svg image overlay on the block body
 * directly and this paint hook is a no-op for that anchor.
 */

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "cmacs-audio-overlay.h"
#include "cmacs-audio-registry.h"
#include "cmacs-audio-stream.h"

#include "lisp.h"
#include "frame.h"
#include "buffer.h"
#include "window.h"

#ifdef HAVE_PGTK
#include "pgtkterm.h"
#include <cairo.h>

static Lisp_Object Qcmacs_audio__streams;

void
cmacs_audio_overlay_init_symbols (void)
{
  Qcmacs_audio__streams = intern_c_string ("cmacs-audio--streams");
  staticpro (&Qcmacs_audio__streams);
}

static void
cmacs_audio__paint_one (cairo_t *cr, CmacsAudioStream *s,
                        int px, int py, int pw, int ph)
{
  if (!s || pw <= 0 || ph <= 0) return;
  g_mutex_lock (&s->frame_mtx);
  cairo_surface_t *surf = s->waveform_surface;
  int sw = s->waveform_w, sh = s->waveform_h;
  if (surf && sw > 0 && sh > 0)
    {
      cairo_save (cr);
      cairo_translate (cr, px, py);
      cairo_scale (cr, (double) pw / sw, (double) ph / sh);
      cairo_set_source_surface (cr, surf, 0, 0);
      cairo_paint (cr);
      cairo_restore (cr);
    }
  g_mutex_unlock (&s->frame_mtx);
}

void
cmacs_audio_overlay_paint (struct frame *f, cairo_t *cr)
{
  if (!f || !cr) return;
  GSList *streams = cmacs_audio_registry_frame_streams (f);
  for (GSList *l = streams; l; l = l->next)
    {
      CmacsAudioStream *s = l->data;
      if (!s || s->state == CMACS_AUDIO_STATE_CLOSED) continue;
      if (s->standalone_frame != f) continue;
      cmacs_audio__paint_one (cr, s,
                              s->standalone_x, s->standalone_y,
                              s->standalone_w, s->standalone_h);
    }
  g_slist_free (streams);
}

#else  /* !HAVE_PGTK */

void cmacs_audio_overlay_init_symbols (void) { }
void cmacs_audio_overlay_paint (struct frame *f, cairo_t *cr)
{ (void) f; (void) cr; }

#endif /* HAVE_PGTK */

#endif /* HAVE_CMACS_AUDIO */
