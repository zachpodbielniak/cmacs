/* cmacs-lrgwindow.c --- output_lrg window/surface lifecycle.

Copyright (C) 2026 Zach Podbielniak

This file is part of cmacs, a fork of GNU Emacs.

SPDX-License-Identifier: AGPL-3.0-or-later

Thin bridge between an Emacs frame and the libregnum LrgFrameSurface that
owns its OS window + GL context.  Keeps the raylib/graylib specifics out of
the terminal/redisplay code, which talks only to the abstract surface vtable
(so 3D/VR surfaces drop in unchanged).  */

#include <config.h>

#ifdef HAVE_CMACS_LRGTERM

#include <libregnum.h>

#include "lisp.h"
#include "frame.h"
#include "cmacs-lrgterm.h"

/* Create the libregnum surface that backs frame F (size WIDTH x HEIGHT,
   window title TITLE).  Stores it on the frame's output.  Returns the
   GrlWindow, or NULL if raylib could not open a window.  */
GrlWindow *
lrg_window_create (struct frame *f, int width, int height, const char *title)
{
  LrgFrameSurface *surface;
  GrlWindow *win;

  eassert (FRAME_LRG_P (f));

  /* Create the window with a transparent framebuffer (a 32-bit ARGB X visual)
     so the `alpha-background' frame parameter can let the desktop show through
     the editor background.  This MUST precede the InitWindow() inside the
     surface constructor -- raylib applies config flags only at window-creation
     time.  It is harmless when transparency is unused: an opaque frame
     (alpha-background = 1.0, the default) clears and fills at full alpha, so
     every pixel ends up opaque.  */
  grl_window_set_config_flags (GRL_FLAG_WINDOW_TRANSPARENT);

  /* render_mode: 0 = 2d, 1 = 3d, 2 = 3dvr.  Pick the matching surface subclass
     (both own the single raylib window).  3dvr currently falls back to the 3D
     surface (mono) until an LrgVRSurface exists -- a graceful degrade.  */
  if (FRAME_LRG_OUTPUT (f)->render_mode != 0)
    {
      Lrg3DSurface *s3 = lrg_3d_surface_new (width, height, title);
      surface = LRG_FRAME_SURFACE (s3);

      /* Apply the launch SPEC tail (e.g. "per-window:workshop"): each
         ':'/','-separated token is an arrangement or environment id; the mode
         registry ignores any it does not recognise.  */
      if (lrg_requested_3d_spec != NULL && *lrg_requested_3d_spec != '\0')
        {
          char *spec = xstrdup (lrg_requested_3d_spec);
          char *save = NULL;
          char *tok = strtok_r (spec, ":,", &save);

          while (tok != NULL)
            {
              if (!lrg_3d_surface_set_arrangement_id (s3, tok))
                lrg_3d_surface_set_environment_id (s3, tok);
              tok = strtok_r (NULL, ":,", &save);
            }
          xfree (spec);
        }
    }
  else
    surface = LRG_FRAME_SURFACE (lrg_2d_surface_new (width, height, title));
  FRAME_LRG_OUTPUT (f)->surface = surface;

  /* Disable raylib's default "Escape quits" -- Emacs owns the ESC key.
     The OS window close button still sets grl_window_should_close, which
     the lrg read_socket maps to a delete-frame event.  */
  grl_input_set_exit_key (GRL_KEY_NULL);

  /* Make the OS window user-resizable -- raylib opens fixed-size windows by
     default (no corner-drag, no maximize button).  GRL_FLAG_WINDOW_RESIZABLE
     maps to GLFW_RESIZABLE; the resulting resize events are picked up in
     lrg_read_socket (grl_window_is_resized) and re-fit the Emacs frame via
     change_frame_size.  */
  win = lrg_frame_surface_get_window (surface);
  if (win == NULL)
    {
      /* The raylib window / GL context could not be created (e.g. no usable
         display -- graylib's grl_window_new now returns NULL instead of a
         half-built window).  Drop the windowless surface so the frame is not
         left with one that later rendering would crash on, and report failure
         to the caller (Flrg_create_frame).  */
      FRAME_LRG_OUTPUT (f)->surface = NULL;
      g_object_unref (surface);
      return NULL;
    }
  grl_window_set_state (win, GRL_FLAG_WINDOW_RESIZABLE);

  return win;
}

/* Return the GrlWindow backing F, or NULL.  */
GrlWindow *
lrg_window_of_frame (struct frame *f)
{
  LrgFrameSurface *s;

  if (!FRAME_LRG_P (f))
    return NULL;
  s = FRAME_LRG_SURFACE (f);
  if (s == NULL)
    return NULL;
  return lrg_frame_surface_get_window (s);
}

/* Begin a render frame on F's surface.  */
void
lrg_window_begin (struct frame *f)
{
  LrgFrameSurface *s = FRAME_LRG_SURFACE (f);
  if (s != NULL)
    lrg_frame_surface_begin_frame (s);
}

/* Present F's surface (swap buffers).  */
void
lrg_window_end (struct frame *f)
{
  LrgFrameSurface *s = FRAME_LRG_SURFACE (f);
  if (s != NULL)
    lrg_frame_surface_end_frame (s);
}

/* Tear down F's surface and its window.  */
void
lrg_window_destroy (struct frame *f)
{
  LrgFrameSurface *s = FRAME_LRG_SURFACE (f);
  if (s != NULL)
    {
      g_clear_object (&s);
      FRAME_LRG_OUTPUT (f)->surface = NULL;
    }
}

/* DPI scale factor of F (1.0 if no surface yet).  */
double
lrg_frame_scale_factor (struct frame *f)
{
  LrgFrameSurface *s;

  if (!FRAME_LRG_P (f))
    return 1.0;
  s = FRAME_LRG_SURFACE (f);
  if (s == NULL)
    return 1.0;
  return (double) lrg_frame_surface_get_scale (s);
}

#endif /* HAVE_CMACS_LRGTERM */
