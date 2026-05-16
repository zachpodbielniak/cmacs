/* cmacs-video-init.c --- Subsystem init + sym registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "lisp.h"
#include "cmacs-video.h"
#include "cmacs-video-stream.h"
#include "cmacs-video-registry.h"
#include "cmacs-video-overlay.h"

#include <gst/gst.h>
#include <stdbool.h>

extern void syms_of_cmacs_video_defuns (void);

static bool init_done       = false;
static bool gst_init_failed = false;

void
syms_of_cmacs_video (void)
{
  /* Symbol setup runs even if gst_init fails so the defuns load and
   * can return nil from cmacs-video-supported-p. */
  cmacs_video_overlay_init_symbols ();
  syms_of_cmacs_video_defuns ();
}

void
init_cmacs_video (void)
{
  if (init_done)
    return;
  init_done = true;

  cmacs_video_registry_init ();

  GError *err = NULL;
  /* Pass NULL arg vectors -- gst_init_check picks up GST_* env vars on
   * its own.  Do NOT pass our argc/argv: gst would consume --gst-*
   * options that may collide with Emacs's own --gst-style flags. */
  if (!gst_init_check (NULL, NULL, &err))
    {
      gst_init_failed = true;
      if (err)
        {
          fprintf (stderr,
                   "cmacs-video: gst_init_check failed: %s\n",
                   err->message);
          g_error_free (err);
        }
      else
        fprintf (stderr, "cmacs-video: gst_init_check failed.\n");
    }
}

#endif /* HAVE_CMACS_VIDEO */
