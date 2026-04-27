/* cmacs-glib-screenshot.c — Frame Cairo surface screenshot DEFUNs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Reads from the live pgtk frame's back surface (FRAME_CR_SURFACE).
 * Two DEFUNs are exposed:
 *
 *   (cmacs-frame-screenshot-rect X Y W H &optional FRAME)
 *       → user-ptr to a freshly allocated cairo_image_surface_t
 *         containing a pixel-perfect copy of the rectangle
 *         (X, Y, W, H) measured in frame-absolute pixels.
 *
 *   (cmacs-screenshot-surface-write-png SURFACE PATH)
 *       → write the surface to PATH as a PNG.  Diagnostic helper.
 *
 * The surface is wrapped via `make_user_ptr' with a finalizer that
 * calls `cairo_surface_destroy', so Elisp callers don't leak memory
 * even on error paths.  Threading from Elisp into a foreign GTK
 * widget is then just `cairo_set_source_surface (cr, surface, …)`.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "frame.h"
#include "cmacs-glib-screenshot.h"

#ifdef HAVE_PGTK
#include "pgtkterm.h"
#include <cairo.h>

/* FRAME_CR_CONTEXT / FRAME_CR_SURFACE live as file-local macros in
   pgtkterm.c; reach into the public output_data struct directly so
   we don't depend on those private definitions. */
#define CMACS_FRAME_CR_CONTEXT(f) ((f)->output_data.pgtk->cr_context)

static void
cmacs_screenshot_surface_finalizer (void *p)
{
  if (p != NULL)
    cairo_surface_destroy ((cairo_surface_t *) p);
}

static cairo_surface_t *
cmacs_screenshot_unwrap_surface (Lisp_Object obj)
{
  if (!USER_PTRP (obj))
    error ("Expected a Cairo screenshot surface (user-ptr)");
  if (XUSER_PTR (obj)->finalizer != cmacs_screenshot_surface_finalizer)
    error ("user-ptr is not a cmacs screenshot surface");
  return (cairo_surface_t *) XUSER_PTR (obj)->p;
}

DEFUN ("cmacs-frame-screenshot-rect",
       Fcmacs_frame_screenshot_rect,
       Scmacs_frame_screenshot_rect, 4, 5, 0,
       doc: /* Return an ARGB32 Cairo surface holding a snapshot of FRAME's
back-buffer rectangle (X Y W H).  Coordinates are frame-absolute
pixels.  When FRAME is nil the selected frame is used.  Only pgtk
frames are supported; signals an error otherwise.

The returned object is a user-ptr; the underlying surface is
destroyed automatically when garbage-collected.  Pass it to the
ink capture window as a background to draw on top of.

usage: (cmacs-frame-screenshot-rect X Y W H &optional FRAME)  */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object w, Lisp_Object h,
   Lisp_Object frame)
{
  struct frame *f;
  cairo_surface_t *src, *dst;
  cairo_t *cr;
  int ix, iy, iw, ih;

  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);
  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  if (NILP (frame))
    f = SELECTED_FRAME ();
  else
    f = decode_window_system_frame (frame);

  if (!FRAME_PGTK_P (f))
    error ("cmacs-frame-screenshot-rect requires a pgtk frame");

  ix = (int) XFIXNUM (x);
  iy = (int) XFIXNUM (y);
  iw = (int) XFIXNUM (w);
  ih = (int) XFIXNUM (h);

  if (iw <= 0 || ih <= 0)
    error ("cmacs-frame-screenshot-rect: width and height must be positive");

  {
    cairo_t *cr_ctx = CMACS_FRAME_CR_CONTEXT (f);
    if (cr_ctx == NULL)
      error ("cmacs-frame-screenshot-rect: frame has no Cairo context");
    src = cairo_get_target (cr_ctx);
  }
  if (src == NULL)
    error ("cmacs-frame-screenshot-rect: frame has no back surface");

  dst = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, iw, ih);
  if (cairo_surface_status (dst) != CAIRO_STATUS_SUCCESS)
    {
      cairo_surface_destroy (dst);
      error ("cmacs-frame-screenshot-rect: failed to allocate destination");
    }

  cr = cairo_create (dst);
  /* Translate so that frame-coord (ix, iy) maps to dst-coord (0, 0). */
  cairo_set_source_surface (cr, src, -ix, -iy);
  cairo_paint (cr);
  cairo_destroy (cr);

  return make_user_ptr (cmacs_screenshot_surface_finalizer, dst);
}

DEFUN ("cmacs-screenshot-surface-write-png",
       Fcmacs_screenshot_surface_write_png,
       Scmacs_screenshot_surface_write_png, 2, 2, 0,
       doc: /* Write SURFACE (a `cmacs-frame-screenshot-rect' result)
to PATH as a PNG file.  Returns t on success, signals an error on
failure.  Useful for diagnostic verification of the screenshot path
without involving the ink capture window.  */)
  (Lisp_Object surface, Lisp_Object path)
{
  cairo_surface_t *s = cmacs_screenshot_unwrap_surface (surface);
  cairo_status_t st;

  CHECK_STRING (path);
  st = cairo_surface_write_to_png (s, SSDATA (path));
  if (st != CAIRO_STATUS_SUCCESS)
    error ("cmacs-screenshot-surface-write-png: %s",
           cairo_status_to_string (st));
  return Qt;
}

#endif /* HAVE_PGTK */

void
syms_of_cmacs_glib_screenshot (void)
{
#ifdef HAVE_PGTK
  defsubr (&Scmacs_frame_screenshot_rect);
  defsubr (&Scmacs_screenshot_surface_write_png);
#endif
}

#endif /* HAVE_CMACS_GLIB */
