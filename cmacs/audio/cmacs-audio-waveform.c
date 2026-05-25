/* cmacs-audio-waveform.c --- PCM samples -> cairo waveform -> SVG.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Pure function: given a buffer of S16LE PCM samples + width/height +
 * a colour, return an SVG string suitable for `(create-image SVG 'svg t)'.
 * Used by:
 *   - cmacs-audio-overlay (paint hook caches a cairo surface)
 *   - cmacs-audio-org (#+BEGIN_AUDIO inline image)
 *   - cmacs-audio-waveform-svg DEFUN (raw text-to-Lisp helper)
 *
 * Renderer: peak/valley pairs per pixel column.  Mono is taken from
 * channel 0 only.  This is intentionally simple; the goal is a glanceable
 * level shape, not a spectrogram.
 */

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include <glib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

/* Public: returns a heap-allocated SVG string (g_free).  Caller owns. */
gchar *cmacs_audio_waveform_to_svg (const int16_t *pcm, gsize n_frames,
                                    int channels, int width, int height,
                                    const char *colour);
gchar *
cmacs_audio_waveform_to_svg (const int16_t *pcm, gsize n_frames,
                             int channels, int width, int height,
                             const char *colour)
{
  if (width <= 0)  width  = 800;
  if (height <= 0) height = 100;
  if (channels <= 0) channels = 1;
  if (!colour || !*colour) colour = "#3f7bd6";

  GString *out = g_string_sized_new (1024 + (gsize) width * 24);
  g_string_append_printf (out,
    "<svg xmlns='http://www.w3.org/2000/svg' "
    "width='%d' height='%d' viewBox='0 0 %d %d'>\n",
    width, height, width, height);
  g_string_append_printf (out,
    "  <rect width='100%%' height='100%%' fill='#111319' />\n");
  /* Centre baseline. */
  g_string_append_printf (out,
    "  <line x1='0' y1='%d' x2='%d' y2='%d' "
    "stroke='#2a3242' stroke-width='1'/>\n",
    height / 2, width, height / 2);

  if (!pcm || n_frames == 0)
    {
      g_string_append (out,
        "  <text x='8' y='16' fill='#666' font-family='monospace' "
        "font-size='11'>(empty)</text>\n</svg>\n");
      return g_string_free (out, FALSE);
    }

  /* Walk in equal slices per pixel column. */
  gsize per_col = n_frames / (gsize) width;
  if (per_col == 0) per_col = 1;

  g_string_append_printf (out,
    "  <g stroke='%s' stroke-width='1' stroke-linecap='round'>\n", colour);

  int half = height / 2;
  for (int x = 0; x < width; x++)
    {
      gsize start = (gsize) x * per_col;
      gsize end   = start + per_col;
      if (end > n_frames) end = n_frames;
      if (start >= n_frames) break;

      int16_t lo = INT16_MAX;
      int16_t hi = INT16_MIN;
      for (gsize i = start; i < end; i++)
        {
          int16_t v = pcm[i * channels];
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
      /* Map [INT16_MIN..INT16_MAX] -> [-half..+half], invert Y. */
      double yh = (double) hi / 32768.0 * half;
      double yl = (double) lo / 32768.0 * half;
      int y1 = half - (int) yh;
      int y2 = half - (int) yl;
      if (y1 == y2) y2 = y1 + 1;
      g_string_append_printf (out,
        "    <line x1='%d' y1='%d' x2='%d' y2='%d'/>\n", x, y1, x, y2);
    }
  g_string_append (out, "  </g>\n</svg>\n");
  return g_string_free (out, FALSE);
}

#endif /* HAVE_CMACS_AUDIO */
