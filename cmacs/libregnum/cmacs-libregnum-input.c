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
  bool          dragging_object;    /* editor: moving the picked node */
  bool          dragging_gizmo;     /* editor: dragging a transform handle */
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

/* Deferred editor selection sync: tell Elisp which node the viewport just
 * selected, so `cmacs-libregnum-editor--current' and the outliner follow a
 * mouse pick / drag.  Like ClickAction, the Lisp eval must run on the cmacs
 * GMainContext, not inside the GTK event handler. */
typedef struct
{
  Lisp_Object buffer;
  gint        id;
} SelectSync;

static gboolean
select_sync_idle (gpointer user)
{
  SelectSync *s = user;
  cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum-editor--on-select"),
                             s->buffer, make_fixnum (s->id));
  g_free (s);
  return G_SOURCE_REMOVE;
}

static void
defer_select_sync (CmacsLibregnumView *v, gint id)
{
  SelectSync *s = g_new0 (SelectSync, 1);
  s->buffer = cmacs_libregnum_view_get_buffer (v);
  s->id = id;
  g_main_context_invoke (cmacs_glib_get_context (), select_sync_idle, s);
}

/* Deferred asset drop: Elisp places the armed asset at the clicked ground
 * point.  Like the others, the eval must run on the cmacs GMainContext. */
typedef struct
{
  Lisp_Object buffer;
  double      x, y, z;
} DropAction;

static gboolean
drop_action_idle (gpointer user)
{
  DropAction *d = user;
  cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum-editor--drop"),
                             d->buffer,
                             list3 (make_float (d->x), make_float (d->y),
                                    make_float (d->z)));
  g_free (d);
  return G_SOURCE_REMOVE;
}

static void
defer_drop (CmacsLibregnumView *v, double x, double y, double z)
{
  DropAction *d = g_new0 (DropAction, 1);
  d->buffer = cmacs_libregnum_view_get_buffer (v);
  d->x = x; d->y = y; d->z = z;
  g_main_context_invoke (cmacs_glib_get_context (), drop_action_idle, d);
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
  /* Reject events outside the window's pixel rectangle.  Without this the
   * function always reported success, so callers (e.g. the button router)
   * could not distinguish a click in the viewport's own window from one in a
   * sibling Emacs window -- which made the viewport swallow EVERY click on the
   * frame and stopped the user selecting any other pane by clicking it. */
  if (x < px || x >= px + pw || y < py || y >= py + ph) return false;
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

  /* Armed asset drop: place the pending asset at the ground point clicked. */
  if (cmacs_libregnum_render_ctx_editor_active (ctx)
      && cmacs_libregnum_render_ctx_editor_armed (ctx))
    {
      double wx, wy, wz;
      cmacs_libregnum_render_ctx_editor_set_armed (ctx, FALSE);
      if (cmacs_libregnum_render_ctx_editor_screen_to_ground
            (ctx, vx, vy, vw, vh, &wx, &wy, &wz))
        defer_drop (v, wx, wy, wz);
      return;
    }

  gint id = cmacs_libregnum_render_ctx_pick (ctx, vx, vy, vw, vh);
  if (id < 0) return;

  /* Visual feedback: select + focus the hit node. */
  cmacs_libregnum_render_ctx_set_selected (ctx, id);
  cmacs_libregnum_render_ctx_focus_node (ctx, id);
  cmacs_libregnum_view_request_redraw (v);

  /* In the editor a node's "path" is its guid, so do NOT find-file it -- just
   * select it in the engine and tell Elisp so the outliner/keys follow. */
  if (cmacs_libregnum_render_ctx_editor_active (ctx))
    {
      cmacs_libregnum_render_ctx_editor_select_node (ctx, id);
      defer_select_sync (v, id);
      return;
    }

  const char *path = NULL;
  gboolean is_dir = FALSE;
  if (!cmacs_libregnum_render_ctx_node_info (ctx, (guint) id, &path, NULL,
                                             &is_dir, NULL, NULL))
    return;

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
     * driving the scene camera.  Unless the view captures all input (the
     * opt-in full-focus game mode), only do so while the pointer is over the
     * game's own window, so motion across other Emacs panes is still routed by
     * Emacs (and does not pin focus to the viewport). */
    CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
    if (cmacs_libregnum_render_ctx_is_game (ctx))
      {
        double gx, gy;
        int gw, gh;
        if (!cmacs_libregnum_render_ctx_get_mouse_capture_all (ctx)
            && !frame_to_view_coords (f, v, x, y, &gx, &gy, &gw, &gh))
          return FALSE;
        cmacs_libregnum_render_ctx_game_mouse_move (ctx, x, y);
        cmacs_libregnum_view_request_redraw (v);
        return true;
      }
  }

  /* Editor: dragging a gizmo handle does an axis-constrained transform. */
  if (drag_state.frame == f && drag_state.dragging_gizmo)
    {
      double vx, vy;
      int vw, vh;
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
        {
          cmacs_libregnum_render_ctx_editor_gizmo_drag (ctx, vx, vy, vw, vh);
          cmacs_libregnum_view_request_redraw (v);
        }
      drag_state.last_x = x;
      drag_state.last_y = y;
      return true;
    }

  /* Editor: dragging a picked node moves it on its ground plane (live;
   * the undo entry is coalesced on button-up). */
  if (drag_state.frame == f && drag_state.dragging_object)
    {
      double vx, vy;
      int vw, vh;
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
        {
          cmacs_libregnum_render_ctx_editor_drag_update (ctx, vx, vy, vw, vh);
          cmacs_libregnum_view_request_redraw (v);
        }
      drag_state.last_x = x;
      drag_state.last_y = y;
      return true;
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

  /* Editor (default): only act on a press that lands inside the viewport's own
   * Emacs window.  `selected_view_for_frame' returns the *selected* window's
   * view, so while the viewport is focused every button event on the frame
   * would otherwise be swallowed here -- including clicks meant for another
   * Emacs pane, which then could not be selected by clicking (only via C-w).  A
   * press outside the viewport window must fall through (return FALSE) so Emacs
   * routes it and selects that pane.  A button-up is still handled when a drag
   * is in progress, so a drag that runs past the window edge ends cleanly.
   *
   * Game (opt-in, mouse_capture_all): the view grabs every frame click while
   * focused -- "full focus" -- which is what a game usually wants. */
  {
    double gx, gy;
    int gw, gh;
    gboolean capture_all = cmacs_libregnum_render_ctx_get_mouse_capture_all
                             (cmacs_libregnum_view_get_render_ctx (v));
    gboolean in_view = frame_to_view_coords (f, v, x, y, &gx, &gy, &gw, &gh);
    gboolean drag_active = drag_state.dragging_left || drag_state.dragging_right
                           || drag_state.dragging_object
                           || drag_state.dragging_gizmo;
    if (!capture_all && !in_view && !(press == 0 && drag_active))
      return FALSE;
  }

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
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (press != 0)
        {
          /* Button down: remember where, start a potential drag. */
          drag_state.press_x = x;
          drag_state.press_y = y;
          drag_state.dragging_object = false;
          drag_state.dragging_gizmo = false;
          /* Editor press priority: a gizmo handle (axis transform) beats an
           * object body (free move) beats empty space (camera orbit). */
          if (cmacs_libregnum_render_ctx_editor_active (ctx))
            {
              double vx, vy;
              int vw, vh;
              if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh)
                  && cmacs_libregnum_render_ctx_editor_gizmo_begin
                       (ctx, vx, vy, vw, vh))
                {
                  drag_state.dragging_gizmo = true;
                  cmacs_libregnum_view_request_redraw (v);
                  return true;
                }
              if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
                {
                  gint id = cmacs_libregnum_render_ctx_pick (ctx, vx, vy,
                                                             vw, vh);
                  if (id >= 0)
                    {
                      cmacs_libregnum_render_ctx_set_selected (ctx, id);
                      cmacs_libregnum_render_ctx_editor_select_node (ctx, id);
                      cmacs_libregnum_render_ctx_editor_drag_begin
                        (ctx, id, vx, vy, vw, vh);
                      defer_select_sync (v, id);
                      drag_state.dragging_object = true;
                      cmacs_libregnum_view_request_redraw (v);
                      return true;
                    }
                }
            }
          drag_state.dragging_left = true;
        }
      else
        {
          /* Button up after dragging a gizmo handle: commit one undo step. */
          if (drag_state.dragging_gizmo)
            {
              cmacs_libregnum_render_ctx_editor_gizmo_end (ctx);
              drag_state.dragging_gizmo = false;
              defer_select_sync
                (v, cmacs_libregnum_render_ctx_get_selected (ctx));
              cmacs_libregnum_view_request_redraw (v);
              return true;
            }
          /* Button up after grabbing an object: commit one undo step. */
          if (drag_state.dragging_object)
            {
              cmacs_libregnum_render_ctx_editor_drag_end (ctx);
              drag_state.dragging_object = false;
              defer_select_sync
                (v, cmacs_libregnum_render_ctx_get_selected (ctx));
              cmacs_libregnum_view_request_redraw (v);
              return true;
            }
          /* A release without meaningful movement is a click (orbit drags
           * move the pointer); pick + act on it. */
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
