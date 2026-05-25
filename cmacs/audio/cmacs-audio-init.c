/* cmacs-audio-init.c --- Subsystem init + symbol registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "lisp.h"
#include "cmacs-audio.h"
#include "cmacs-audio-stream.h"
#include "cmacs-audio-registry.h"
#include "cmacs-audio-overlay.h"

#include <gst/gst.h>
#include <stdbool.h>
#include <stdio.h>

extern void syms_of_cmacs_audio_defuns (void);
extern void cmacs_audio__stream_init_symbols (void);

static bool init_done = false;

void
syms_of_cmacs_audio (void)
{
  cmacs_audio__stream_init_symbols ();
  cmacs_audio_overlay_init_symbols ();
  syms_of_cmacs_audio_defuns ();
}

void
init_cmacs_audio (void)
{
  if (init_done) return;
  init_done = true;

  cmacs_audio_registry_init ();

  /* gst_init_check is idempotent; the no-op-on-repeat behaviour means
   * sharing this call with cmacs-video is safe regardless of ordering. */
  GError *err = NULL;
  if (!gst_init_check (NULL, NULL, &err))
    {
      if (err)
        {
          fprintf (stderr, "cmacs-audio: gst_init_check failed: %s\n",
                   err->message);
          g_error_free (err);
        }
      else
        fprintf (stderr, "cmacs-audio: gst_init_check failed.\n");
    }
}

#endif /* HAVE_CMACS_AUDIO */
