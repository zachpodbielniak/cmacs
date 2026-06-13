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
#include <gtk/gtk.h>

/* Per-frame drag state. */
typedef struct
{
  struct frame *frame;
  CmacsLibregnumView *view;         /* the view that owns the active drag */
  double        last_x, last_y;
  double        press_x, press_y;   /* left-button-down position */
  double        rpress_x, rpress_y; /* right-button-down position (menu vs orbit) */
  bool          dragging_left;
  bool          dragging_right;
  bool          dragging_middle;    /* middle-drag pans (CAD nav profile) */
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
  gint        id;
  double      vx, vy;        /* view-local click pixel (for globe ray-pick) */
} ClickAction;

static gboolean
click_action_idle (gpointer user)
{
  ClickAction *a = user;
  /* Route through one Elisp dispatcher so each mode decides what a node
   * click means.  Its default preserves the tree behaviour (find-file /
   * drill-to); the gnuseye globe routes to its entity detail view.  Args:
   * (BUFFER (ID PATH IS-DIR)). */
  cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum--node-clicked"),
                             a->buffer,
                             list5 (make_fixnum (a->id),
                                    (a->path && a->path[0])
                                      ? build_string (a->path) : Qnil,
                                    a->is_dir ? Qt : Qnil,
                                    make_float (a->vx),
                                    make_float (a->vy)));
  g_free (a->path);
  g_free (a);
  return G_SOURCE_REMOVE;
}

/* Non-editor right-click: same capture as a left click (id + stable path +
 * view pixel), dispatched to the context-menu router instead.  The Elisp
 * side must NOT pop the menu inside this dispatch (it runs during the
 * pselect wait) -- it re-schedules onto the command loop. */
static gboolean
node_menu_idle (gpointer user)
{
  ClickAction *a = user;
  cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum--node-context-menu"),
                             a->buffer,
                             list5 (make_fixnum (a->id),
                                    (a->path && a->path[0])
                                      ? build_string (a->path) : Qnil,
                                    a->is_dir ? Qt : Qnil,
                                    make_float (a->vx),
                                    make_float (a->vy)));
  g_free (a->path);
  g_free (a);
  return G_SOURCE_REMOVE;
}

static void
defer_node_menu (CmacsLibregnumView *v, CmacsLibregnumRenderCtx *ctx,
                 gint id, double vx, double vy)
{
  const gchar *path = NULL;
  gboolean is_dir = FALSE;
  if (id >= 0)
    cmacs_libregnum_render_ctx_node_info (ctx, (guint) id, &path, NULL,
                                          &is_dir, NULL, NULL);
  ClickAction *a = g_new0 (ClickAction, 1);
  a->buffer = cmacs_libregnum_view_get_buffer (v);
  a->path = (path && path[0]) ? g_strdup (path) : NULL;
  a->is_dir = is_dir;
  a->id = id;
  a->vx = vx;
  a->vy = vy;
  g_main_context_invoke (cmacs_glib_get_context (), node_menu_idle, a);
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

/* Deferred right-click context menu: Elisp pops a GTK menu (x-popup-menu) over
 * the entity under the cursor.  The actual menu must NOT pop here -- this idle
 * runs inside cmacs_glib_dispatch (Emacs's pselect wait), and starting a nested
 * GTK menu loop there would re-enter the GLib dispatch.  So the Elisp side
 * (`cmacs-libregnum-editor--context-menu') re-schedules the pop onto the
 * command loop via a 0-delay timer; here we only hand off buffer + picked node
 * id (-1 = empty space) + the frame-pixel click point (x-popup-menu POSITION)
 * + the ground point (so an empty-space "Add" places where you clicked). */
typedef struct
{
  Lisp_Object buffer;
  gint        id;             /* picked node id, or -1 for empty space */
  double      fx, fy;         /* frame-relative pixels = menu anchor */
  double      gx, gy, gz;     /* world ground point under the click */
  bool        have_ground;
} ContextMenuAction;

static gboolean
context_menu_idle (gpointer user)
{
  ContextMenuAction *c = user;
  Lisp_Object pos = c->have_ground
    ? list5 (make_float (c->fx), make_float (c->fy),
             make_float (c->gx), make_float (c->gy), make_float (c->gz))
    : list2 (make_float (c->fx), make_float (c->fy));
  cmacs_dispatch_safe_call3 (intern ("cmacs-libregnum-editor--context-menu"),
                             c->buffer, make_fixnum (c->id), pos);
  g_free (c);
  return G_SOURCE_REMOVE;
}

static void
defer_context_menu (CmacsLibregnumView *v, gint id, double fx, double fy,
                    bool have_ground, double gx, double gy, double gz)
{
  ContextMenuAction *c = g_new0 (ContextMenuAction, 1);
  c->buffer = cmacs_libregnum_view_get_buffer (v);
  c->id = id; c->fx = fx; c->fy = fy;
  c->have_ground = have_ground; c->gx = gx; c->gy = gy; c->gz = gz;
  g_main_context_invoke (cmacs_glib_get_context (), context_menu_idle, c);
}

static struct window *window_showing_view (Lisp_Object window,
                                           CmacsLibregnumView *v);

/* Convert a frame-pixel click (X,Y) to view-local pixels (origin
 * top-left) for the window showing view V, and report the view size.
 * Returns false if the click is outside the window or sizes are bad. */
static bool
frame_to_view_coords (struct frame *f, CmacsLibregnumView *v,
                      double x, double y,
                      double *vx, double *vy, int *vw, int *vh)
{
  if (!f || !FRAME_LIVE_P (f)) return false;
  struct window *win = window_showing_view (FRAME_ROOT_WINDOW (f), v);
  if (!win) return false;
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

  /* Visual feedback: select + focus the hit node (only on a hit). */
  if (id >= 0)
    {
      cmacs_libregnum_render_ctx_set_selected (ctx, id);
      cmacs_libregnum_render_ctx_focus_node (ctx, id);
      cmacs_libregnum_view_request_redraw (v);
    }

  /* In the editor a node's "path" is its guid, so do NOT find-file it -- just
   * select it in the engine and tell Elisp so the outliner/keys follow.
   * Ctrl+click toggles the node in the multi-selection instead of replacing. */
  if (cmacs_libregnum_render_ctx_editor_active (ctx))
    {
      if (id < 0) return;            /* editor: empty-space click is a no-op */
      /* Query the modifier state via the current GDK event so we do not need
       * to thread a modifier parameter through pgtkterm.c. */
      gboolean ctrl_held = FALSE;
      {
        GdkEvent *ev = gtk_get_current_event ();
        if (ev)
          {
            GdkModifierType state = 0;
            gdk_event_get_state (ev, &state);
            ctrl_held = (state & GDK_CONTROL_MASK) != 0;
            gdk_event_free (ev);
          }
      }
      if (ctrl_held)
        {
          /* Ctrl+click toggles this node in the multi-selection: add if it is
           * not already in the selection, remove if it is. */
          GArray *ids = cmacs_libregnum_render_ctx_editor_selected_ids (ctx);
          gboolean found = FALSE;
          guint si;
          for (si = 0; si < ids->len; si++)
            if (g_array_index (ids, gint, si) == id)
              { found = TRUE; break; }
          g_array_unref (ids);
          if (found)
            cmacs_libregnum_render_ctx_editor_select_remove (ctx, id);
          else
            cmacs_libregnum_render_ctx_editor_select_add (ctx, id);
          cmacs_libregnum_view_request_redraw (v);
          defer_select_sync (v, cmacs_libregnum_render_ctx_get_selected (ctx));
          return;
        }
      /* Normal click: replace the selection. */
      cmacs_libregnum_render_ctx_editor_select_node (ctx, id);
      defer_select_sync (v, id);
      return;
    }

  /* Non-editor (e.g. the gnuseye globe): defer the click onto the cmacs
   * context -- INCLUDING an empty-globe miss (id == -1), carrying the view
   * pixel so the globe can map it to a lat/lon (measurement, deselect). */
  const char *path = NULL;
  gboolean is_dir = FALSE;
  if (id >= 0)
    cmacs_libregnum_render_ctx_node_info (ctx, (guint) id, &path, NULL,
                                          &is_dir, NULL, NULL);

  ClickAction *a = g_new0 (ClickAction, 1);
  a->buffer = cmacs_libregnum_view_get_buffer (v);
  a->path = (path && path[0]) ? g_strdup (path) : NULL;
  a->is_dir = is_dir;
  a->id = id;
  a->vx = vx;
  a->vy = vy;
  g_main_context_invoke (cmacs_glib_get_context (), click_action_idle, a);
}

/* CRITICAL (applies to every helper below): these run inside a GTK
 * signal callback.  We MUST NOT call any Lisp `F*' helper that can
 * xsignal -- e.g. Fframe_selected_window's CHECK_LIVE_FRAME,
 * Fwindow_buffer's CHECK_WINDOW.  A signal here longjmps through GLib's
 * signal_emit_unlocked_R, leaving the emission stack corrupted.  Read
 * straight off the C structs instead.  `f' can also be NULL when the
 * GtkWidget that received the event is not a cmacs frame (tooltips,
 * menus, popovers, a split's transient widget). */

/* Recursively find the leaf window in a window tree whose pixel
 * rectangle contains (X,Y).  Pure C-struct traversal (see warning
 * above). */
static struct window *
leaf_window_at (Lisp_Object window, double x, double y)
{
  while (WINDOWP (window))
    {
      struct window *w = XWINDOW (window);
      if (BUFFERP (w->contents))
        {
          int l = WINDOW_LEFT_PIXEL_EDGE (w);
          int t = WINDOW_TOP_PIXEL_EDGE  (w);
          if (x >= l && x < l + WINDOW_PIXEL_WIDTH (w)
              && y >= t && y < t + WINDOW_PIXEL_HEIGHT (w))
            return w;
        }
      else if (WINDOWP (w->contents))
        {
          struct window *hit = leaf_window_at (w->contents, x, y);
          if (hit) return hit;
        }
      window = w->next;
    }
  return NULL;
}

/* The libregnum view whose window currently sits under the pointer
 * (X,Y in frame pixels), or NULL.  Unlike selected_view_for_frame this
 * does NOT require the view's window to be the frame's *selected*
 * window -- mouse orbit/pan/zoom then work over any visible viewport,
 * so a viewer that left an info/source pane selected (e.g. the CAD
 * model/G-code viewers, where Doom re-selects the file buffer after
 * find-file) still rotates on right-drag.  A press that lands outside
 * every viewport returns NULL and falls through to Emacs, so other
 * panes are still selectable by clicking them. */
static CmacsLibregnumView *
pointer_view_for_frame (struct frame *f, double x, double y,
                        struct window **win_out)
{
  if (!f) return NULL;
  if (cmacs_libregnum_view_registry_empty_p ()) return NULL;
  if (!FRAME_LIVE_P (f)) return NULL;
  struct window *w = leaf_window_at (FRAME_ROOT_WINDOW (f), x, y);
  if (!w || !BUFFERP (w->contents)) return NULL;
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (w->contents);
  if (v && win_out) *win_out = w;
  return v;
}

/* The leaf window in WINDOW's tree displaying view V's buffer, or NULL.
 * frame_to_view_coords uses this so coordinate mapping follows the
 * view's actual window wherever it lives, not the selected window. */
static struct window *
window_showing_view (Lisp_Object window, CmacsLibregnumView *v)
{
  while (WINDOWP (window))
    {
      struct window *w = XWINDOW (window);
      if (BUFFERP (w->contents))
        {
          if (cmacs_libregnum_view_for_buffer (w->contents) == v)
            return w;
        }
      else if (WINDOWP (w->contents))
        {
          struct window *hit = window_showing_view (w->contents, v);
          if (hit) return hit;
        }
      window = w->next;
    }
  return NULL;
}

gboolean
cmacs_libregnum_handle_motion (struct frame *f, double x, double y)
{
  if (!f || !FRAME_LIVE_P (f)) return FALSE;
  /* During an active drag the pointer may stray outside the viewport
   * window -- GTK keeps delivering motion to the implicit grab -- so keep
   * driving the view that owns the drag.  Otherwise route to whatever
   * viewport sits under the pointer (not the selected window). */
  bool drag_active = (drag_state.frame == f && drag_state.view
                      && (drag_state.dragging_left || drag_state.dragging_right
                          || drag_state.dragging_middle
                          || drag_state.dragging_object
                          || drag_state.dragging_gizmo));
  CmacsLibregnumView *v = drag_active ? drag_state.view
                                      : pointer_view_for_frame (f, x, y, NULL);
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
      && (drag_state.dragging_left || drag_state.dragging_right
          || drag_state.dragging_middle))
    {
      double dx = x - drag_state.last_x;
      double dy = y - drag_state.last_y;
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      /* CAD navigation profile (matches FreeCAD's "CAD" preset, and what a
       * 3-D viewer user reaches for): left OR right drag orbits; middle drag
       * pans; scroll zooms.  A right-click WITHOUT movement still pops the
       * context menu (handled in the button-release branch). */
      if (drag_state.dragging_middle)
        cmacs_libregnum_render_ctx_pan_camera (ctx, dx, dy);
      else
        cmacs_libregnum_render_ctx_orbit_camera (ctx, dx, dy);
      cmacs_libregnum_view_request_redraw (v);
    }
  else
    {
      /* Idle hover: ray-pick the node under the cursor so the overlay can
       * label it (markers with label-mode "hover").  Cheap (AABB tests);
       * only redraw when the hovered node changes.  Harmless for scenes
       * whose nodes use the legacy label policy. */
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      double vx, vy;
      int vw, vh;
      if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
        {
          gint hit = cmacs_libregnum_render_ctx_pick (ctx, vx, vy, vw, vh);
          if (hit != cmacs_libregnum_render_ctx_get_hovered (ctx))
            {
              cmacs_libregnum_render_ctx_set_hovered (ctx, hit);
              cmacs_libregnum_view_request_redraw (v);
            }
        }
    }
  drag_state.frame  = f;
  drag_state.last_x = x;
  drag_state.last_y = y;
  return drag_state.dragging_left || drag_state.dragging_right
         || drag_state.dragging_middle;
}

gboolean
cmacs_libregnum_handle_button (struct frame *f, int button, int press,
                               double x, double y)
{
  if (!f || !FRAME_LIVE_P (f)) return FALSE;
  /* Route to the viewport under the pointer (press) or, for a button-up
   * that ends a drag, the view that owns the drag (the pointer may have
   * run past the window edge).  NOT the selected window -- so right-drag
   * orbits even while an info/source pane is the selected window. */
  bool ending_drag = (press == 0 && drag_state.frame == f && drag_state.view
                      && (drag_state.dragging_left || drag_state.dragging_right
                          || drag_state.dragging_middle
                          || drag_state.dragging_object
                          || drag_state.dragging_gizmo));
  CmacsLibregnumView *v = ending_drag ? drag_state.view
                                      : pointer_view_for_frame (f, x, y, NULL);
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
                           || drag_state.dragging_middle
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
  drag_state.view   = v;
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
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (press != 0)
        {
          /* Right-press: remember where, arm a potential pan drag. */
          drag_state.dragging_right = true;
          drag_state.rpress_x = x;
          drag_state.rpress_y = y;
        }
      else
        {
          /* A right-release without meaningful movement is a context-menu
             click (a pan moves the pointer).  In the editor, ray-pick the node
             under the cursor (id may be -1 for empty space), capture the ground
             point, and defer the menu to Elisp -- which pops it from the
             command loop.  A right-drag still pans (handled in the motion
             handler off `dragging_right'); only the release branches here. */
          bool moved = (fabs (x - drag_state.rpress_x)
                        + fabs (y - drag_state.rpress_y)) > 5.0;
          drag_state.dragging_right = false;
          if (!moved && cmacs_libregnum_render_ctx_editor_active (ctx))
            {
              double vx, vy, gx = 0, gy = 0, gz = 0;
              int vw, vh;
              gint id = -1;
              bool ground = false;
              if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
                {
                  id = cmacs_libregnum_render_ctx_pick (ctx, vx, vy, vw, vh);
                  ground = cmacs_libregnum_render_ctx_editor_screen_to_ground
                             (ctx, vx, vy, vw, vh, &gx, &gy, &gz);
                }
              defer_context_menu (v, id, x, y, ground, gx, gy, gz);
            }
          else if (!moved)
            {
              /* Non-editor views (scenes, the gnuseye globe): right-click
               * pops an entity / view context menu, routed like a left
               * click (id + stable path + view pixel). */
              double vx = 0.0, vy = 0.0;
              int vw, vh;
              gint id = -1;
              if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
                id = cmacs_libregnum_render_ctx_pick (ctx, vx, vy, vw, vh);
              defer_node_menu (v, ctx, id, vx, vy);
            }
        }
      return true;
    }
  if (button == 2)
    {
      /* Middle button: pan drag (CAD nav profile).  No click action. */
      drag_state.dragging_middle = (press != 0);
      return true;
    }
  return false;
}

gboolean
cmacs_libregnum_handle_scroll (struct frame *f, double dx, double dy,
                               double x, double y)
{
  (void) dx;
  /* Zoom whatever viewport is under the pointer (not the selected window). */
  CmacsLibregnumView *v = pointer_view_for_frame (f, x, y, NULL);
  if (!v) return FALSE;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (cmacs_libregnum_render_ctx_is_game (ctx))
    return true;   /* a hosted game manages its own zoom; ignore scroll */
  cmacs_libregnum_render_ctx_zoom_camera (ctx, dy);
  cmacs_libregnum_view_request_redraw (v);
  return true;
}

#endif /* HAVE_CMACS_LIBREGNUM */
