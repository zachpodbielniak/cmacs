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
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"

#include <math.h>

/* Per-frame drag state. */
typedef struct
{
  struct frame *frame;
  double        last_x, last_y;
  double        press_x, press_y;   /* left-button-down position */
  bool          dragging_left;
  bool          dragging_right;
} DragState;

static DragState drag_state = { 0 };

/* ── Click → open file / drill into directory ───────────────────────
 *
 * A left click (press + release without dragging) ray-picks the node
 * under the cursor and acts on it.  The action evaluates Lisp
 * (find-file / a drill command), which must NOT run inside the GTK
 * button-event handler -- a signal there would longjmp through GLib's
 * emission machinery.  So we capture the result and defer it onto the
 * cmacs GMainContext, where cmacs_dispatch_safe_call* is safe.  The
 * buffer is GC-rooted by the view registry, so stashing the Lisp_Object
 * for the brief hop is fine. */
typedef struct
{
  Lisp_Object buffer;
  gchar      *path;
  bool        is_dir;
} ClickAction;

static gboolean
click_action_idle (gpointer user)
{
  ClickAction *a = user;
  if (a->path && a->path[0])
    {
      if (a->is_dir)
        cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum--drill-to"),
                                   a->buffer, build_string (a->path));
      else
        cmacs_dispatch_safe_call1 (intern ("find-file"),
                                   build_string (a->path));
    }
  g_free (a->path);
  g_free (a);
  return G_SOURCE_REMOVE;
}

/* Convert a frame-pixel click (X,Y) to view-local pixels (origin
 * top-left) for the window showing view V, and report the view size.
 * Returns false if the click is outside the window or sizes are bad. */
static bool
frame_to_view_coords (struct frame *f, CmacsLibregnumView *v,
                      double x, double y,
                      double *vx, double *vy, int *vw, int *vh)
{
  Lisp_Object sw = f->selected_window;
  if (!WINDOWP (sw)) return false;
  struct window *win = XWINDOW (sw);
  int px = WINDOW_LEFT_PIXEL_EDGE (win);
  int py = WINDOW_TOP_PIXEL_EDGE  (win);
  int pw = WINDOW_PIXEL_WIDTH     (win);
  int ph = WINDOW_PIXEL_HEIGHT    (win);
  int w = 0, h = 0;
  cmacs_libregnum_view_get_size (v, &w, &h);
  if (pw <= 0 || ph <= 0 || w <= 0 || h <= 0) return false;
  *vx = (x - px) * (double) w / pw;
  *vy = (y - py) * (double) h / ph;
  *vw = w; *vh = h;
  return true;
}

/* On a non-drag left click, pick the node under the cursor, select +
 * focus it, and queue its open/drill action. */
static void
handle_click (struct frame *f, CmacsLibregnumView *v, double x, double y)
{
  double vx, vy;
  int vw, vh;
  if (!frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh)) return;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  gint id = cmacs_libregnum_render_ctx_pick (ctx, vx, vy, vw, vh);
  if (id < 0) return;

  const char *path = NULL;
  gboolean is_dir = FALSE;
  if (!cmacs_libregnum_render_ctx_node_info (ctx, (guint) id, &path, NULL,
                                             &is_dir, NULL, NULL))
    return;

  /* Visual feedback: select + focus the hit node. */
  cmacs_libregnum_render_ctx_set_selected (ctx, id);
  cmacs_libregnum_render_ctx_focus_node (ctx, id);
  cmacs_libregnum_view_request_redraw (v);

  /* Defer the Lisp action onto the cmacs context. */
  ClickAction *a = g_new0 (ClickAction, 1);
  a->buffer = cmacs_libregnum_view_get_buffer (v);
  a->path = g_strdup (path);
  a->is_dir = is_dir;
  g_main_context_invoke (cmacs_glib_get_context (), click_action_idle, a);
}

static CmacsLibregnumView *
selected_view_for_frame (struct frame *f)
{
  /* `f' can be NULL when the GtkWidget that received the event is
   * not a cmacs frame (tooltips, menus, popovers, the widget that
   * passes through during a window split before the new frame is
   * mapped).
   *
   * CRITICAL: this runs inside a GTK signal callback.  We MUST NOT
   * call any Lisp `F*' helper that can xsignal -- e.g.
   * Fframe_selected_window's CHECK_LIVE_FRAME, Fwindow_buffer's
   * CHECK_WINDOW.  A signal here longjmps through GLib's
   * signal_emit_unlocked_R, leaving the emission stack
   * corrupted.  Read straight off the C structs instead. */
  if (!f) return NULL;
  if (cmacs_libregnum_view_registry_empty_p ()) return NULL;
  if (!FRAME_LIVE_P (f)) return NULL;
  Lisp_Object sw = f->selected_window;
  if (!WINDOWP (sw)) return NULL;
  Lisp_Object buf = XWINDOW (sw)->contents;
  if (!BUFFERP (buf)) return NULL;
  return cmacs_libregnum_view_for_buffer (buf);
}

gboolean
cmacs_libregnum_handle_motion (struct frame *f, double x, double y)
{
  CmacsLibregnumView *v = selected_view_for_frame (f);
  if (!v) return FALSE;

  {
    /* In game mode, forward the pointer to the hosted game instead of
     * driving the scene camera. */
    CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
    if (cmacs_libregnum_render_ctx_is_game (ctx))
      {
        cmacs_libregnum_render_ctx_game_mouse_move (ctx, x, y);
        cmacs_libregnum_view_request_redraw (v);
        return true;
      }
  }

  if (drag_state.frame == f
      && (drag_state.dragging_left || drag_state.dragging_right))
    {
      double dx = x - drag_state.last_x;
      double dy = y - drag_state.last_y;
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (drag_state.dragging_left)
        cmacs_libregnum_render_ctx_orbit_camera (ctx, dx, dy);
      else /* right-drag pans the viewport so you can reach things */
        cmacs_libregnum_render_ctx_pan_camera (ctx, dx, dy);
      cmacs_libregnum_view_request_redraw (v);
    }
  drag_state.frame  = f;
  drag_state.last_x = x;
  drag_state.last_y = y;
  return drag_state.dragging_left || drag_state.dragging_right;
}

gboolean
cmacs_libregnum_handle_button (struct frame *f, int button, int press,
                               double x, double y)
{
  CmacsLibregnumView *v = selected_view_for_frame (f);
  if (!v) return FALSE;

  {
    /* In game mode, forward mouse buttons to the hosted game. Map the X11
     * button numbers (1=left, 2=middle, 3=right) to graylib's
     * GrlMouseButton (0=left, 1=right, 2=middle). */
    CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
    if (cmacs_libregnum_render_ctx_is_game (ctx))
      {
        int grl_btn = (button == 1) ? 0 : (button == 3) ? 1 : 2;
        cmacs_libregnum_render_ctx_game_mouse_button (ctx, grl_btn, press != 0);
        cmacs_libregnum_view_request_redraw (v);
        return true;
      }
  }

  drag_state.frame  = f;
  drag_state.last_x = x;
  drag_state.last_y = y;
  if (button == 1)
    {
      if (press != 0)
        {
          /* Button down: remember where, start a potential drag. */
          drag_state.press_x = x;
          drag_state.press_y = y;
          drag_state.dragging_left = true;
        }
      else
        {
          /* Button up: a release without meaningful movement is a click
           * (orbit drags move the pointer); pick + act on it. */
          bool moved = (fabs (x - drag_state.press_x)
                        + fabs (y - drag_state.press_y)) > 5.0;
          drag_state.dragging_left = false;
          if (!moved)
            handle_click (f, v, x, y);
        }
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
  if (cmacs_libregnum_render_ctx_is_game (ctx))
    return true;   /* a hosted game manages its own zoom; ignore scroll */
  cmacs_libregnum_render_ctx_zoom_camera (ctx, dy);
  cmacs_libregnum_view_request_redraw (v);
  return true;
}

#endif /* HAVE_CMACS_LIBREGNUM */
