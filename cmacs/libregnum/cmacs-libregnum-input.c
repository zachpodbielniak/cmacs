/* cmacs-libregnum-input.c --- route PGTK input into libregnum views.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Uses only the plain-C render-context API (cmacs-libregnum-render.h)
 * so it can include frame.h / window.h without the libregnum-Color
 * typedef conflict. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "frame.h"
#include "window.h"
#include "buffer.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"

/* Per-frame drag state. */
typedef struct
{
  struct frame *frame;
  double        last_x, last_y;
  bool          dragging_left;
  bool          dragging_right;
} DragState;

static DragState drag_state = { 0 };

static CmacsLibregnumView *
selected_view_for_frame (struct frame *f)
{
  Lisp_Object frame;
  XSETFRAME (frame, f);
  Lisp_Object sw = Fframe_selected_window (frame);
  if (!WINDOWP (sw)) return NULL;
  Lisp_Object buf = Fwindow_buffer (sw);
  if (!BUFFERP (buf)) return NULL;
  return cmacs_libregnum_view_for_buffer (buf);
}

gboolean
cmacs_libregnum_handle_motion (struct frame *f, double x, double y)
{
  CmacsLibregnumView *v = selected_view_for_frame (f);
  if (!v) return FALSE;

  if (drag_state.frame == f && drag_state.dragging_left)
    {
      double dx = x - drag_state.last_x;
      double dy = y - drag_state.last_y;
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      cmacs_libregnum_render_ctx_orbit_camera (ctx, dx, dy);
      cmacs_libregnum_view_request_redraw (v);
    }
  drag_state.frame  = f;
  drag_state.last_x = x;
  drag_state.last_y = y;
  return drag_state.dragging_left;
}

gboolean
cmacs_libregnum_handle_button (struct frame *f, int button, int press,
                               double x, double y)
{
  CmacsLibregnumView *v = selected_view_for_frame (f);
  if (!v) return FALSE;

  drag_state.frame  = f;
  drag_state.last_x = x;
  drag_state.last_y = y;
  if (button == 1)
    {
      drag_state.dragging_left = press != 0;
      return true;
    }
  if (button == 3)
    {
      drag_state.dragging_right = press != 0;
      return true;
    }
  return false;
}

gboolean
cmacs_libregnum_handle_scroll (struct frame *f, double dx, double dy,
                               double x, double y)
{
  (void) dx; (void) x; (void) y;
  CmacsLibregnumView *v = selected_view_for_frame (f);
  if (!v) return FALSE;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  cmacs_libregnum_render_ctx_zoom_camera (ctx, dy);
  cmacs_libregnum_view_request_redraw (v);
  return true;
}

#endif /* HAVE_CMACS_LIBREGNUM */
