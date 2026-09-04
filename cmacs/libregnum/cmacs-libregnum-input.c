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
  bool          dragging_scene;     /* non-editor: moving a scene node */
  gint          scene_drag_id;      /* the node being dragged, or -1 */
  gint          scene_drag_cand;    /* node under the press, before the
                                       drag threshold is crossed */
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

/* ── Scene node drag → deferred Elisp callback ──────────────────────
 *
 * Reports the world point under the cursor for the node being dragged.
 * Lisp does the moving, because the authoritative position lives in the
 * scene's own graph: moving the drawable here would look right until the
 * next layout pass quietly put it back. */
typedef struct
{
  Lisp_Object buffer;
  gchar      *path;
  double      x, y, z;
  int         phase;          /* 0 begin, 1 update, 2 end */
} SceneDrag;

static gboolean
scene_drag_idle (gpointer user)
{
  SceneDrag *d = user;
  cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum--node-dragged"),
                             d->buffer,
                             list5 ((d->path && d->path[0])
                                      ? build_string (d->path) : Qnil,
                                    make_float (d->x),
                                    make_float (d->y),
                                    make_float (d->z),
                                    make_fixnum (d->phase)));
  g_free (d->path);
  g_free (d);
  return G_SOURCE_REMOVE;
}

static void
defer_scene_drag (CmacsLibregnumView *v, CmacsLibregnumRenderCtx *ctx,
                  gint id, double wx, double wy, double wz, int phase)
{
  const gchar *path = NULL;
  SceneDrag *d;

  if (id >= 0)
    cmacs_libregnum_render_ctx_node_info (ctx, (guint) id, &path, NULL,
                                          NULL, NULL, NULL);
  d = g_new0 (SceneDrag, 1);
  d->buffer = cmacs_libregnum_view_get_buffer (v);
  d->path = (path && path[0]) ? g_strdup (path) : NULL;
  d->x = wx; d->y = wy; d->z = wz;
  d->phase = phase;
  g_main_context_invoke (cmacs_glib_get_context (), scene_drag_idle, d);
}

/* ── Hover → deferred Elisp callback ────────────────────────────────
 *
 * Hover already drove the overlay's label; nothing ever told Lisp about
 * it.  That is the whole reason "hover a department to light up its
 * files" was not expressible: the information stopped in C.
 *
 * Fires only when the hovered node CHANGES (the caller checks), so this
 * is a handful of dispatches per second of mouse movement, not one per
 * motion event.  Same defer-onto-the-GMainContext discipline as a click:
 * a hover handler evaluates Lisp, which must not happen inside the GTK
 * motion handler. */
static gboolean
hover_action_idle (gpointer user)
{
  ClickAction *a = user;
  cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum--node-hovered"),
                             a->buffer,
                             list2 (make_fixnum (a->id),
                                    (a->path && a->path[0])
                                      ? build_string (a->path) : Qnil));
  g_free (a->path);
  g_free (a);
  return G_SOURCE_REMOVE;
}

static void
defer_node_hover (CmacsLibregnumView *v, CmacsLibregnumRenderCtx *ctx,
                  gint id)
{
  const gchar *path = NULL;
  ClickAction *a;

  if (id >= 0)
    cmacs_libregnum_render_ctx_node_info (ctx, (guint) id, &path, NULL,
                                          NULL, NULL, NULL);
  a = g_new0 (ClickAction, 1);
  a->buffer = cmacs_libregnum_view_get_buffer (v);
  a->path = (path && path[0]) ? g_strdup (path) : NULL;
  a->id = id;
  g_main_context_invoke (cmacs_glib_get_context (), hover_action_idle, a);
}

/* ── 2D image-mode input → deferred Elisp callbacks ──────────────────────
 * When a view is in image-display mode, mouse events map to DOCUMENT pixels
 * (via image_view_to_doc) and are dispatched to per-event Elisp routers that
 * forward to buffer-local hook functions the editor (imgedit/vidstudio) sets.
 * Same defer-onto-GMainContext discipline as the node callbacks above (never
 * run Lisp / pop a menu inside the GTK handler). */

/* Whether the current left-drag has moved off the press pixel (click vs drag). */
static gboolean image_left_moved;

/* TRUE while a left-drag started inside the timeline strip (scrub/trim), so
   motion + release route to the timeline hooks instead of the paint tools. */
static gboolean image_timeline_active;

typedef struct
{
  Lisp_Object buffer;
  const char *event;      /* interned dispatcher name (static string) */
  int         dx, dy;     /* document pixel */
  int         button;     /* X button (1/2/3) */
  int         mods;       /* 1=shift 2=ctrl 4=meta */
  int         fx, fy;     /* frame pixel (context menu only) */
} ImageAction;

/* Current keyboard modifiers from the GTK event (bit 1 shift, 2 ctrl, 4 meta). */
static int
image_current_mods (void)
{
  int m = 0;
  GdkEvent *ev = gtk_get_current_event ();
  if (ev)
    {
      GdkModifierType state = 0;
      gdk_event_get_state (ev, &state);
      if (state & GDK_SHIFT_MASK)   m |= 1;
      if (state & GDK_CONTROL_MASK) m |= 2;
      if (state & GDK_MOD1_MASK)    m |= 4;
      gdk_event_free (ev);
    }
  return m;
}

static gboolean
image_action_idle (gpointer user)
{
  ImageAction *a = user;
  cmacs_dispatch_safe_call2 (intern (a->event), a->buffer,
                             list4 (make_fixnum (a->dx), make_fixnum (a->dy),
                                    make_fixnum (a->button),
                                    make_fixnum (a->mods)));
  g_free (a);
  return G_SOURCE_REMOVE;
}

static gboolean
image_menu_idle (gpointer user)
{
  ImageAction *a = user;
  /* (BUFFER (DX DY FX FY CLIP-ID)) -- FX/FY are frame pixels for x-popup-menu;
   * CLIP-ID (a->button) is the timeline clip under the cursor, or -1.  The
   * Elisp router must re-schedule the actual pop onto the command loop. */
  cmacs_dispatch_safe_call2 (intern ("cmacs-libregnum--image-context-menu"),
                             a->buffer,
                             list5 (make_fixnum (a->dx), make_fixnum (a->dy),
                                    make_fixnum (a->fx), make_fixnum (a->fy),
                                    make_fixnum (a->button)));
  g_free (a);
  return G_SOURCE_REMOVE;
}

static void
defer_image (CmacsLibregnumView *v, const char *event,
             int dx, int dy, int button, int mods)
{
  ImageAction *a = g_new0 (ImageAction, 1);
  a->buffer = cmacs_libregnum_view_get_buffer (v);
  a->event = event;
  a->dx = dx; a->dy = dy;
  a->button = button; a->mods = mods;
  g_main_context_invoke (cmacs_glib_get_context (), image_action_idle, a);
}

/* Timeline strip event: (FRAME CLIP-ID EDGE 0) via image_action_idle,
   reusing the dx/dy/button fields.  EDGE: 0 body, 1 right, 2 left. */
static void
defer_image_timeline (CmacsLibregnumView *v, const char *event,
                      int frame, int clip_id, int edge)
{
  ImageAction *a = g_new0 (ImageAction, 1);
  a->buffer = cmacs_libregnum_view_get_buffer (v);
  a->event = event;
  a->dx = frame; a->dy = clip_id; a->button = edge; a->mods = 0;
  g_main_context_invoke (cmacs_glib_get_context (), image_action_idle, a);
}

static void
defer_image_menu (CmacsLibregnumView *v, int dx, int dy, int fx, int fy,
                  int clip_id)
{
  ImageAction *a = g_new0 (ImageAction, 1);
  a->buffer = cmacs_libregnum_view_get_buffer (v);
  a->dx = dx; a->dy = dy; a->fx = fx; a->fy = fy;
  a->button = clip_id;          /* clip under the cursor, or -1 */
  g_main_context_invoke (cmacs_glib_get_context (), image_menu_idle, a);
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
  /* Map against the window BODY (text area), matching the paint rect
     (window_box TEXT_AREA in the lrg/pgtk compositors) and the FBO size
     (window-body).  Using the full WINDOW_PIXEL_* rect here -- which includes
     the mode line -- both stretched the mapping and let clicks on the modeline
     fall through to the view instead of Emacs. */
  int px, py, pw, ph;
  window_box (win, TEXT_AREA, &px, &py, &pw, &ph);
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
      /* Only where the scene wants it.  Flying to whatever was clicked
         is right for a scene you navigate BY clicking, and wrong for
         one where the click starts something worth watching -- it
         snatches the view away from the animation it just began. */
      if (cmacs_libregnum_render_ctx_click_focuses (ctx))
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
                          || drag_state.dragging_scene
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

  /* Image mode: middle-drag pans; left-drag paints (deferred --image-drag
   * with document coords).  Motion outside the view is still honoured during a
   * drag (the pointer may run past the edge). */
  {
    CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
    if (cmacs_libregnum_render_ctx_is_image (ctx))
      {
        double vx, vy;
        int vw, vh, dx = 0, dy = 0;
        gboolean in = frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh);
        if (drag_state.dragging_middle && drag_state.view == v)
          {
            double s, px, py;
            cmacs_libregnum_render_ctx_image_get_view (ctx, &s, &px, &py);
            cmacs_libregnum_render_ctx_image_set_view
              (ctx, s, px + (x - drag_state.last_x),
               py + (y - drag_state.last_y));
            drag_state.last_x = x; drag_state.last_y = y;
            cmacs_libregnum_view_request_redraw (v);
            return true;
          }
        if (drag_state.dragging_left && drag_state.view == v
            && image_timeline_active)
          {
            /* Scrub/trim: report the frame + clip under the cursor. */
            int tf = 0, tcid = -1;
            int tedge = 0;
            cmacs_libregnum_render_ctx_image_timeline_hit
              (ctx, vx, vy, vw, vh, &tf, &tcid, &tedge);
            defer_image_timeline (v, "cmacs-libregnum--image-timeline-drag",
                                  tf, tcid, tedge);
            cmacs_libregnum_view_request_redraw (v);
            return true;
          }
        if (drag_state.dragging_left && drag_state.view == v)
          {
            cmacs_libregnum_render_ctx_image_view_to_doc (ctx, vx, vy, &dx, &dy);
            image_left_moved = TRUE;
            defer_image (v, "cmacs-libregnum--image-drag", dx, dy, 1,
                         image_current_mods ());
            cmacs_libregnum_view_request_redraw (v);
            return true;
          }
        return in ? true : FALSE;   /* consume hover over the view */
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

  /* A press that has travelled far enough becomes a node drag.  Below
   * that distance it stays a click in waiting, so ordinary clicking is
   * exactly as forgiving as it was before dragging existed. */
  if (drag_state.frame == f && !drag_state.dragging_scene
      && drag_state.dragging_left && drag_state.scene_drag_cand >= 0
      && (fabs (x - drag_state.press_x)
          + fabs (y - drag_state.press_y)) > 5.0)
    {
      double vx, vy, wx, wy, wz;
      int vw, vh;
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh)
          && cmacs_libregnum_render_ctx_editor_screen_to_ground
               (ctx, vx, vy, vw, vh, &wx, &wy, &wz))
        {
          drag_state.dragging_scene = true;
          drag_state.scene_drag_id = drag_state.scene_drag_cand;
          defer_scene_drag (v, ctx, drag_state.scene_drag_id,
                            wx, wy, wz, 0);
        }
      drag_state.scene_drag_cand = -1;
    }

  /* Non-editor scene: dragging a node reports the world point under the
   * cursor, and the scene moves it.  Checked before the editor path
   * because the two are mutually exclusive and this one is cheaper. */
  if (drag_state.frame == f && drag_state.dragging_scene)
    {
      double vx, vy, wx, wy, wz;
      int vw, vh;
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh)
          && cmacs_libregnum_render_ctx_editor_screen_to_ground
               (ctx, vx, vy, vw, vh, &wx, &wy, &wz))
        defer_scene_drag (v, ctx, drag_state.scene_drag_id, wx, wy, wz, 1);
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
      /* Default is the CAD navigation profile (FreeCAD's "CAD" preset,
       * and what a 3-D viewer user reaches for): left OR right drag
       * orbits; middle drag pans; scroll zooms.  A context that calls
       * set_right_drag_pans instead gets the map profile: left orbits,
       * right pans -- which is what a map-like scene wants, and what a
       * user without a middle button can actually reach.
       *
       * Either way a right-click WITHOUT movement still pops the context
       * menu; that is decided in the button-release branch, which only
       * fires the menu when the pointer did not move. */
      if (drag_state.dragging_middle
          || (drag_state.dragging_right
              && cmacs_libregnum_render_ctx_right_drag_pans_p (ctx)))
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
              /* Tell Lisp too, so a mode can react to hover with more
               * than a label -- lighting up everything in the hovered
               * department, for one.  Deferred, never inline. */
              defer_node_hover (v, ctx, hit);
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
                          || drag_state.dragging_scene
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
                           || drag_state.dragging_scene
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

  /* Image mode: left = paint (press/drag/release or click), middle = pan,
   * right-release = context menu.  All in DOCUMENT pixels; the Elisp editor's
   * hook functions implement the active tool. */
  {
    CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
    if (cmacs_libregnum_render_ctx_is_image (ctx))
      {
        double vx, vy;
        int vw, vh, dx = 0, dy = 0, mods = image_current_mods ();
        gboolean in = frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh);
        if (in)
          cmacs_libregnum_render_ctx_image_view_to_doc (ctx, vx, vy, &dx, &dy);
        if (button == 1)
          {
            int tf = 0, tcid = -1;
            int tedge = 0;
            if (press)
              {
                /* A press inside the timeline strip starts a scrub/select/trim
                 * instead of a paint stroke. */
                if (in && cmacs_libregnum_render_ctx_image_timeline_hit
                            (ctx, vx, vy, vw, vh, &tf, &tcid, &tedge))
                  {
                    image_timeline_active = TRUE;
                    drag_state.frame = f; drag_state.view = v;
                    drag_state.dragging_left = true;
                    drag_state.press_x = x; drag_state.press_y = y;
                    drag_state.last_x = x; drag_state.last_y = y;
                    defer_image_timeline
                      (v, "cmacs-libregnum--image-timeline-press",
                       tf, tcid, tedge);
                    cmacs_libregnum_view_request_redraw (v);
                    return true;
                  }
                image_timeline_active = FALSE;
                drag_state.frame = f; drag_state.view = v;
                drag_state.dragging_left = true;
                drag_state.press_x = x; drag_state.press_y = y;
                drag_state.last_x = x; drag_state.last_y = y;
                image_left_moved = FALSE;
                defer_image (v, "cmacs-libregnum--image-press", dx, dy, 1, mods);
              }
            else if (image_timeline_active)
              {
                cmacs_libregnum_render_ctx_image_timeline_hit
                  (ctx, vx, vy, vw, vh, &tf, &tcid, &tedge);
                image_timeline_active = FALSE;
                drag_state.dragging_left = false;
                defer_image_timeline
                  (v, "cmacs-libregnum--image-timeline-release", tf, tcid, tedge);
                cmacs_libregnum_view_request_redraw (v);
                return true;
              }
            else
              {
                drag_state.dragging_left = false;
                /* A press+release with no motion is a click (fill/eyedropper/
                 * text); with motion it is a completed stroke/shape. */
                defer_image (v, image_left_moved
                                  ? "cmacs-libregnum--image-release"
                                  : "cmacs-libregnum--image-click",
                             dx, dy, 1, mods);
              }
            cmacs_libregnum_view_request_redraw (v);
            return true;
          }
        if (button == 2)          /* middle drag pans */
          {
            drag_state.frame = f; drag_state.view = v;
            drag_state.dragging_middle = (press != 0);
            drag_state.last_x = x; drag_state.last_y = y;
            return true;
          }
        if (button == 3)          /* right release -> context menu */
          {
            if (!press)
              {
                /* Report the timeline clip under the cursor (if any) so the
                 * menu commands act on it without prompting. */
                int tf = 0, tcid = -1;
                int tedge = 0;
                if (in)
                  cmacs_libregnum_render_ctx_image_timeline_hit
                    (ctx, vx, vy, vw, vh, &tf, &tcid, &tedge);
                defer_image_menu (v, dx, dy, (int) x, (int) y, tcid);
              }
            return true;
          }
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
          drag_state.dragging_scene = false;
          drag_state.scene_drag_id = -1;
          drag_state.scene_drag_cand = -1;
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
          /* Non-editor scene that asked for draggable nodes: remember
           * what is under the press, but do NOT start dragging yet and
           * do NOT consume the event.
           *
           * Grabbing on press makes every click on a node a drag, so the
           * release returns early and the click never happens -- no
           * expand, and a view that feels like it demands pixel-perfect
           * aim because most presses produce no visible response.  The
           * drag begins only once the pointer has actually travelled,
           * which is the same threshold a click already used. */
          drag_state.scene_drag_cand = -1;
          if (!cmacs_libregnum_render_ctx_editor_active (ctx)
              && cmacs_libregnum_render_ctx_drag_nodes (ctx))
            {
              double vx, vy;
              int vw, vh;
              if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
                drag_state.scene_drag_cand =
                  cmacs_libregnum_render_ctx_pick (ctx, vx, vy, vw, vh);
            }
          drag_state.dragging_left = true;
        }
      else
        {
          /* Button up after moving a scene node: tell the scene the drag
           * is over so it can settle (re-solve, unpin, whatever it does). */
          if (drag_state.dragging_scene)
            {
              double vx, vy, wx, wy, wz;
              int vw, vh;
              if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh)
                  && cmacs_libregnum_render_ctx_editor_screen_to_ground
                       (ctx, vx, vy, vw, vh, &wx, &wy, &wz))
                defer_scene_drag (v, ctx, drag_state.scene_drag_id,
                                  wx, wy, wz, 2);
              drag_state.dragging_scene = false;
              drag_state.scene_drag_id = -1;
              drag_state.scene_drag_cand = -1;
              drag_state.dragging_left = false;
              cmacs_libregnum_view_request_redraw (v);
              return true;
            }
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
             command loop.  A right-DRAG orbits or pans (handled in the
             motion handler off `dragging_right', per the context's
             navigation profile); only the release branches here, and
             only a release without movement is a menu click. */
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
  if (cmacs_libregnum_render_ctx_is_image (ctx))
    {
      /* Zoom the image about the cursor (keeps the doc point under it fixed). */
      double vx, vy;
      int vw, vh;
      if (frame_to_view_coords (f, v, x, y, &vx, &vy, &vw, &vh))
        cmacs_libregnum_render_ctx_image_zoom_at (ctx, vx, vy,
                                                  dy > 0 ? 1.1 : 0.9);
      cmacs_libregnum_view_request_redraw (v);
      return true;
    }
  /* GDK reports a positive delta for scrolling DOWN, and zoom_camera
     moves closer for a positive amount -- so passing DY straight
     through means scrolling down moves you closer, the opposite of what
     every map and 3-D viewer does.  A context can ask for the
     conventional direction; the default is left alone so scenes that
     shipped with the old one are not silently flipped. */
  cmacs_libregnum_render_ctx_zoom_camera
    (ctx, cmacs_libregnum_render_ctx_wheel_up_zooms_in_p (ctx) ? -dy : dy);
  cmacs_libregnum_view_request_redraw (v);
  return true;
}

#endif /* HAVE_CMACS_LIBREGNUM */
