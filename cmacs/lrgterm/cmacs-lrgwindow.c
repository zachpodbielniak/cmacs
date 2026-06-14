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
  Lrg2DSurface *surface;

  eassert (FRAME_LRG_P (f));

  /* Only LRG_RENDER_MODE_2D is implemented today; 3d/3dvr are reserved.  */
  surface = lrg_2d_surface_new (width, height, title);
  FRAME_LRG_OUTPUT (f)->surface = LRG_FRAME_SURFACE (surface);

  /* Disable raylib's default "Escape quits" -- Emacs owns the ESC key.
     The OS window close button still sets grl_window_should_close, which
     the lrg read_socket maps to a delete-frame event.  */
  grl_input_set_exit_key (GRL_KEY_NULL);

  /* Make the OS window user-resizable -- raylib opens fixed-size windows by
     default (no corner-drag, no maximize button).  GRL_FLAG_WINDOW_RESIZABLE
     maps to GLFW_RESIZABLE; the resulting resize events are picked up in
     lrg_read_socket (grl_window_is_resized) and re-fit the Emacs frame via
     change_frame_size.  */
  {
    GrlWindow *win = lrg_2d_surface_get_window (surface);
    if (win != NULL)
      grl_window_set_state (win, GRL_FLAG_WINDOW_RESIZABLE);
  }

  return lrg_2d_surface_get_window (surface);
}

/* Return the GrlWindow backing F, or NULL.  */
GrlWindow *
lrg_window_of_frame (struct frame *f)
{
  LrgFrameSurface *s;

  if (!FRAME_LRG_P (f))
    return NULL;
  s = FRAME_LRG_SURFACE (f);
  if (s == NULL || !LRG_IS_2D_SURFACE (s))
    return NULL;
  return lrg_2d_surface_get_window (LRG_2D_SURFACE (s));
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
